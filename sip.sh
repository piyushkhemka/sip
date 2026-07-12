#!/usr/bin/env bash
#
# sip 💧 — a low-latency status line for Claude Code. "Every prompt takes a sip."
#
# Renders five or six pipe-separated segments, in this order:
#   💵 $<session> ($<daily> today) [| <emoji> 5h <pct>% (resets in <time>) · <emoji> 7d <pct>% (resets in <time>)] | 💧 <resp> · <daily> today | 🧠 <used>k/<total>k (<pct>%) | 🤖 <model> (<effort> effort) | 🔄 Turn: <n>
#
# The usage segment mirrors Claude Code's own `/usage`: the 5-hour and 7-day
# (weekly) Pro/Max rate-limit percentages and time until each resets, read
# straight from the payload's `rate_limits` field — no extra API calls, no
# added token cost. Each window gets a status emoji at the same thresholds as
# context color-coding: ✅ <33% · ⚠️ 33-66% · 🚨 67-84% · 🚫 >=85%. Omitted
# entirely when rate_limits is absent (free tier, or before the session's
# first API response) — never shown with placeholder values.
#
# The 💧 segment estimates the water consumed (datacenter cooling + electricity
# generation) for the response, derived from output tokens:
#     water_mL = output_tokens / 1000 * K
# K defaults to 1.5 mL per 1,000 output tokens (a citable central estimate for
# the total footprint); override with SIP_WATER_ML_PER_1K_TOKENS. See the README
# for the derivation and sources. It is an estimate — the honest range is wide.
#
# Design: status lines run locally and cost zero API tokens, so the budget is
# latency. The hot path is one `awk` pass over the session transcript (real user
# turns + output-token totals) plus one `jq` process (payload parse, daily-cost
# and daily-water bookkeeping via --slurpfile), then one atomic state write. The
# transcript scan is skipped entirely when the transcript hasn't grown since the
# last render (see "transcript cache" below). Portable to the bash 3.2 that
# ships with macOS (no bash-4 features).
#
# Debug: set SIP_DEBUG=/path/to/log to append each raw stdin payload.

set -u

# ---------------------------------------------------------------------------
# State: per-session {cost, out(put tokens)} for today, self-resets on date
# rollover. Prefer the plugin data dir, then XDG, then ~/.claude/sip.
# ---------------------------------------------------------------------------
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.claude}/sip}"
STATE_FILE="$STATE_DIR/daily.json"

[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$STATE_FILE" ] || printf '{}\n' >"$STATE_FILE" 2>/dev/null || true

# Water constant: mL per 1,000 output tokens (tunable, validated numeric).
K="${SIP_WATER_ML_PER_1K_TOKENS:-1.5}"
case $K in ''|*[!0-9.]*|*.*.*|.*|*.) K=1.5 ;; esac

# Today's date, computed once in bash (portable: standard `date`, no reliance
# on jq's strflocaltime, which requires jq >= 1.6 and would otherwise fail
# every single render on older jq builds).
TODAY=$(date +%Y-%m-%d 2>/dev/null) || TODAY="1970-01-01"
NOW_EPOCH=$(date +%s 2>/dev/null) || NOW_EPOCH=0

# ---------------------------------------------------------------------------
# Read all of stdin with a bash builtin (no `cat` exec).
# ---------------------------------------------------------------------------
IFS= read -r -d '' input || true

# Optional debug capture.
if [ -n "${SIP_DEBUG:-}" ]; then
  printf '%s\n' "$input" >>"$SIP_DEBUG" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Extract transcript_path and session_id from the raw payload with bash
# parameter expansion (no subprocess), tolerant of optional whitespace after
# the colon.
# ---------------------------------------------------------------------------
extract_field() {
  # $1 = field name, echoes the raw string value (unquoted) or "" if absent.
  local f="$1" v=""
  case $input in
    *"\"$f\""*)
      v=${input#*\"$f\"}
      v=${v#*:}
      while [ "${v# }" != "$v" ]; do v=${v# }; done
      v=${v#\"}
      v=${v%%\"*}
      ;;
  esac
  printf '%s' "$v"
}
tpath=$(extract_field "transcript_path")
sid=$(extract_field "session_id")
[ -n "$sid" ] || sid="default"

# Filesystem-safe cache key derived from session_id (defense in depth against
# a crafted session_id containing path-traversal characters).
sid_safe=${sid//[^A-Za-z0-9_-]/}
[ -n "$sid_safe" ] || sid_safe="default"
CACHE_FILE="$STATE_DIR/tcache-$sid_safe"

# ---------------------------------------------------------------------------
# Transcript scan: real user turns, plus the sum and the last of assistant
# `output_tokens`. A turn is a top-level `type:"user"` prompt whose content is
# NOT a tool_result (matched on the JSON structural marker "type":"tool_result"
# — not the bare word, so a user prompt merely discussing tool results isn't
# miscounted), excluding subagent (sidechain) and meta lines.
#
# Cache: skip the awk pass entirely when the transcript's byte size hasn't
# changed since the last render for this session (the common case — status
# lines re-render on permission prompts, vim-mode toggles, refreshInterval,
# etc. without new transcript content). Cache is a tiny per-session sidecar
# file (not daily.json) so this lookup needs no jq call. On any size change,
# a full rescan runs (not a byte-range incremental read, to avoid the
# correctness risk of splitting a JSONL line across two scans).
# ---------------------------------------------------------------------------
turn=0; out_sum=0; out_last=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  cur_size=$(( $(wc -c <"$tpath" 2>/dev/null || echo 0) ))

  cached_size=0; cached_turn=0; cached_out=0; cached_last=0
  if [ -f "$CACHE_FILE" ]; then
    IFS=' ' read -r cached_size cached_turn cached_out cached_last <"$CACHE_FILE" 2>/dev/null
  fi
  case $cached_size in ''|*[!0-9]*) cached_size=0 ;; esac
  case $cached_turn in ''|*[!0-9]*) cached_turn=0 ;; esac
  case $cached_out  in ''|*[!0-9]*) cached_out=0  ;; esac
  case $cached_last in ''|*[!0-9]*) cached_last=0 ;; esac

  if [ "$cached_size" -gt 0 ] && [ "$cached_size" -eq "$cur_size" ]; then
    turn=$cached_turn; out_sum=$cached_out; out_last=$cached_last
  else
    read -r turn out_sum out_last <<EOF
$(awk -- '
  /"type":"user"/ && !/"type":"tool_result"/ && !/"isSidechain":true/ && !/"isMeta":true/ { t++ }
  /"type":"assistant"/ {
    if (match($0, /"output_tokens":[0-9]+/)) {
      v = substr($0, RSTART + 16, RLENGTH - 16) + 0
      s += v; last = v
    }
  }
  END { printf "%d %d %d", t + 0, s + 0, last + 0 }
' "$tpath" 2>/dev/null)
EOF
    case $turn in ''|*[!0-9]*) turn=0 ;; esac
    case $out_sum in ''|*[!0-9]*) out_sum=0 ;; esac
    case $out_last in ''|*[!0-9]*) out_last=0 ;; esac

    # Best-effort cache write (atomic); failures are harmless (next render
    # just rescans).
    ctmp="$CACHE_FILE.$$"
    if printf '%s %s %s %s\n' "$cur_size" "$turn" "$out_sum" "$out_last" >"$ctmp" 2>/dev/null; then
      mv -f "$ctmp" "$CACHE_FILE" 2>/dev/null || rm -f "$ctmp" 2>/dev/null
    fi
  fi
fi

# ---------------------------------------------------------------------------
# The single jq program. Reads the payload on stdin and the state via
# --slurpfile ($st is a 1-element array). Args: $k (mL/1k tok), $outsum (this
# session's total output tokens), $outlast (last response's output tokens),
# $today (bash-computed date). All prior-state fields are defensively coerced
# to numbers so a corrupted/malformed individual session record can never
# throw a jq runtime error — the reset-on-failure path below is reserved for
# a genuinely unparseable state FILE, not ordinary payload or state quirks.
# Emits TWO raw lines: unit-separator (\x1f) delimited display fields (NOT
# tab — bash's `IFS=$'\t' read` collapses consecutive tab delimiters as "IFS
# whitespace" and silently drops empty fields, corrupting the alignment of
# every field after one), then the new state JSON.
# ---------------------------------------------------------------------------
read -r -d '' JQ_PROG <<'JQ' || true
def modelshort:
  (.model.id // "") as $id
  | ( $id | ltrimstr("claude-") | gsub("[0-9]{8}"; "") | split("-")
      | map(select(length > 0)) ) as $toks
  | ( $toks | map(select(. == "opus" or . == "sonnet" or . == "haiku")) | .[0] ) as $fam
  | ( $toks | map(select(test("^[0-9]+$"))) | join(".") ) as $ver
  | if $fam != null then (if $ver == "" then $fam else $fam + " " + $ver end)
    elif ((.model.display_name // "") | length) > 0 then .model.display_name
    else "unknown" end ;

def numOr($default): if (type == "number") then . else $default end;

# Format a non-negative number to exactly one decimal digit as a string. jq's
# number->string conversion silently drops a trailing ".0" (1.0 prints as
# "1"), which would make fmt_resp/fmt_daily inconsistently show "1 mL" next
# to "12.9 mL" for the same field. Splitting into whole/tenths and
# string-concatenating sidesteps that entirely.
def fmt1dp($v):
  ($v * 10 | round) as $tenths
  | ($tenths / 10 | floor) as $whole
  | ($tenths - ($whole * 10)) as $frac
  | "\($whole).\($frac)";

# Water formatters. Per-response is always mL; daily auto-scales to L at >=1000.
def fmt_resp($ml):
  if   $ml <= 0   then "0.0 mL"
  elif $ml < 0.1  then "<0.1 mL"
  else "\(fmt1dp($ml)) mL" end ;
def fmt_daily($ml):
  if   $ml <= 0    then "0 mL"
  elif $ml >= 1000 then "\(fmt1dp($ml / 1000)) L"
  else "\(($ml | round)) mL" end ;

($st[0] // {}) as $prev
| (if ($prev.date == $today) then ($prev.sessions // {}) else {} end) as $base_raw
# Defensively coerce every prior session's fields to numbers so a corrupted
# individual record can never cause a runtime type error.
| ( $base_raw | with_entries(.value |= {
      cost: ((.cost // 0) | numOr(0)),
      out:  ((.out  // 0) | numOr(0))
    }) ) as $base
| (.session_id // "default") as $sid
| ((.cost.total_cost_usd // 0) | numOr(0)) as $scost
| ( $base + { ($sid): { cost: $scost, out: $outsum } } ) as $sessions
| ( [ $sessions[] | .cost ] | add // 0 ) as $daily_cost
| ( [ $sessions[] | .out  ] | add // 0 ) as $daily_out
| ( $daily_out * $k / 1000 ) as $daily_ml
| ( $outlast * $k / 1000 ) as $resp_ml
| { date: $today, sessions: $sessions } as $newstate
| (.context_window // {}) as $cw
| ((($cw.total_input_tokens // 0) | numOr(0))) as $used_raw
| ((($cw.context_window_size // 0) | numOr(0))) as $total_raw
| ( $used_raw / 1000 | floor ) as $used_k
| ( $total_raw / 1000 | floor ) as $total_k
# Derive pct from the same raw token counts as used_k/total_k so the percent
# can never visually contradict the displayed fraction; only fall back to the
# payload's own used_percentage when context_window_size is absent/zero.
| ( if $total_raw > 0 then ( (100 * $used_raw / $total_raw) | floor )
    else ( ($cw.used_percentage // 0) | numOr(0) | floor ) end ) as $pct
| modelshort as $model
| ( (.effort.level // "") as $el | if ($el | length) > 0 then $el else "unknown" end ) as $effort
# Rate-limit usage (mirrors /usage): read straight from the payload, no extra
# cost. Each window is independently optional; emit "" for any missing piece
# so bash can tell "absent" from "present at 0%" and omit the whole segment
# only when neither window has data.
| (.rate_limits.five_hour // null) as $rl5
| (.rate_limits.seven_day // null) as $rl7
| ( if $rl5 != null and (($rl5.used_percentage // null) != null)
    then (($rl5.used_percentage | numOr(0)) | floor | tostring) else "" end ) as $pct5s
| ( if $rl5 != null and (($rl5.resets_at // null) != null)
    then ((($rl5.resets_at | numOr($now)) - $now) | floor | tostring) else "" end ) as $resets5s
| ( if $rl7 != null and (($rl7.used_percentage // null) != null)
    then (($rl7.used_percentage | numOr(0)) | floor | tostring) else "" end ) as $pct7s
| ( if $rl7 != null and (($rl7.resets_at // null) != null)
    then ((($rl7.resets_at | numOr($now)) - $now) | floor | tostring) else "" end ) as $resets7s
| ( [ ($scost|tostring), ($used_k|tostring), ($total_k|tostring), ($pct|tostring),
      $model, $effort, ($daily_cost|tostring),
      fmt_resp($resp_ml), fmt_daily($daily_ml),
      $pct5s, $resets5s, $pct7s, $resets7s ] | join("\u001f") ),
  ( $newstate | tojson )
JQ

# ---------------------------------------------------------------------------
# Lightweight mkdir-based lock around the read(state)-merge-write cycle to
# reduce (bound, not perfectly eliminate) lost updates when two Claude Code
# sessions render concurrently. mkdir is atomic and near-zero cost in the
# uncontended case (the overwhelming majority of renders). Bounded retries
# with a stale-lock takeover so a crashed holder can never wedge future
# renders; on exhausting retries we proceed WITHOUT the lock (fail-open) so
# the status line itself never hangs — worst case is an imprecise daily total,
# never a broken render.
# ---------------------------------------------------------------------------
LOCK_DIR="$STATE_FILE.lock"
have_lock=0
attempt=0
while [ "$attempt" -lt 8 ]; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    have_lock=1
    break
  fi
  lock_mtime=$( { stat -f%m "$LOCK_DIR" 2>/dev/null || stat -c%Y "$LOCK_DIR" 2>/dev/null; } )
  if [ -n "${lock_mtime:-}" ]; then
    now_ts=$(date +%s 2>/dev/null || echo 0)
    age=$(( now_ts - lock_mtime ))
    [ "$age" -gt 2 ] && rmdir "$LOCK_DIR" 2>/dev/null
  fi
  sleep 0.02 2>/dev/null || sleep 1
  attempt=$((attempt + 1))
done
[ "$have_lock" -eq 1 ] && trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# Validate STATE_FILE's own JSON *before* the one real jq call, and reset it
# only if IT is unparseable. This is deliberately decoupled from whether the
# main jq run below succeeds: a malformed/truncated stdin payload (or any
# other reason the main run fails) must never be treated as "the state file
# must be bad" and trigger a reset — that previously destroyed a perfectly
# healthy day's worth of every other session's cost/water the moment a single
# bad payload came through. Only this file's own parseability earns a reset.
if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
  printf '{}\n' >"$STATE_FILE" 2>/dev/null || true
fi

# Run jq once. If it still fails now (state file is known-good, so this means
# the payload or an argument was bad), leave STATE_FILE untouched — $out stays
# empty, the bash-side ${var:-default} fallbacks below degrade the display
# safely, and the "don't persist an empty newstate" guard further down means
# nothing gets written. The next render simply retries against the same,
# still-intact, persisted history.
run_jq() {
  jq -r --slurpfile st "$STATE_FILE" \
     --arg today "$TODAY" --argjson now "$NOW_EPOCH" \
     --argjson k "$K" --argjson outsum "$out_sum" --argjson outlast "$out_last" \
     "$JQ_PROG" <<<"$input" 2>/dev/null
}
out=$(run_jq) || out=""

# Split: first line = delimited display fields, remainder = new state JSON.
line1=${out%%$'\n'*}
newstate=${out#*$'\n'}

IFS=$'\x1f' read -r scost used_k total_k pct model effort daily resp_water daily_water \
  pct5 resets5 pct7 resets7 <<<"$line1"

# Defaults, in case jq produced nothing or a short row.
scost=${scost:-0}; used_k=${used_k:-0}; total_k=${total_k:-0}; pct=${pct:-0}
model=${model:-unknown}; effort=${effort:-unknown}; daily=${daily:-0}
resp_water=${resp_water:-"0.0 mL"}; daily_water=${daily_water:-"0 mL"}
pct5=${pct5:-}; resets5=${resets5:-}; pct7=${pct7:-}; resets7=${resets7:-}
case $pct in ''|*[!0-9]*) pct=0 ;; esac
case $pct5 in *[!0-9]*) pct5="" ;; esac
case $resets5 in *[!0-9-]*) resets5="" ;; esac
case $pct7 in *[!0-9]*) pct7="" ;; esac
case $resets7 in *[!0-9-]*) resets7="" ;; esac

# Persist updated state (atomic: write temp, then rename) — inside the lock.
if [ -n "$newstate" ] && [ "$newstate" != "$line1" ]; then
  tmp="$STATE_FILE.$$"
  if printf '%s\n' "$newstate" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
fi

if [ "$have_lock" -eq 1 ]; then
  rmdir "$LOCK_DIR" 2>/dev/null
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# Assemble the line, in order: 💵 cost, usage (rate-limit), 💧 water,
# 🧠 context, 🤖 model, 🔄 turn. Context usage is still ANSI color-coded
# (<33 green | 33-66 yellow | 67-84 orange | >=85 red). Rate-limit usage
# instead gets a status emoji per window at the same thresholds:
# ✅ <33 · ⚠️ 33-66 · 🚨 67-84 · 🚫 >=85 — the emoji itself is the signal, so
# no ANSI color is layered on top of it.
# ---------------------------------------------------------------------------
reset=$'\033[0m'
color_for_pct() {
  local p="$1"
  if   [ "$p" -lt 33 ]; then printf '%s' $'\033[32m'        # green
  elif [ "$p" -le 66 ]; then printf '%s' $'\033[33m'        # yellow
  elif [ "$p" -le 84 ]; then printf '%s' $'\033[38;5;208m'  # orange
  else                       printf '%s' $'\033[31m'        # red
  fi
}

emoji_for_pct() {
  local p="$1"
  if   [ "$p" -lt 33 ]; then printf '\xe2\x9c\x85'          # ✅
  elif [ "$p" -le 66 ]; then printf '\xe2\x9a\xa0\xef\xb8\x8f' # ⚠️
  elif [ "$p" -le 84 ]; then printf '\xf0\x9f\x9a\xa8'      # 🚨
  else                       printf '\xf0\x9f\x9a\xab'      # 🚫
  fi
}

# "3d4h", "2h14m", "45m", "now" — omits the smaller unit when it's zero.
fmt_duration() {
  local secs="$1" h m d
  case $secs in ''|*[!0-9-]*) printf '?'; return ;; esac
  if [ "$secs" -le 0 ]; then printf 'now'; return; fi
  if [ "$secs" -lt 3600 ]; then
    printf '%dm' "$(( secs / 60 ))"
  elif [ "$secs" -lt 86400 ]; then
    h=$(( secs / 3600 )); m=$(( (secs % 3600) / 60 ))
    if [ "$m" -eq 0 ]; then printf '%dh' "$h"; else printf '%dh%dm' "$h" "$m"; fi
  else
    d=$(( secs / 86400 )); h=$(( (secs % 86400) / 3600 ))
    if [ "$h" -eq 0 ]; then printf '%dd' "$d"; else printf '%dd%dh' "$d" "$h"; fi
  fi
}

# "resets in 3h50m" / "resets now" — grammatically correct wrapper around
# fmt_duration so the zero/past case doesn't read as "resets in now".
fmt_resets_phrase() {
  local secs="$1" d
  d=$(fmt_duration "$secs")
  if [ "$d" = "now" ]; then printf 'resets now'; else printf 'resets in %s' "$d"; fi
}

color=$(color_for_pct "$pct")

printf -v scost_f '%.2f' "$scost" 2>/dev/null || scost_f="0.00"
printf -v daily_f '%.2f' "$daily" 2>/dev/null || daily_f="0.00"

seg_cost="💵 \$$scost_f (\$$daily_f today)"
seg_water="💧 $resp_water · $daily_water today"
seg_context="🧠 ${color}${used_k}k/${total_k}k (${pct}%)${reset}"
seg_model="🤖 $model ($effort effort)"
seg_turn="🔄 Turn: $turn"

# Usage segment: omitted entirely when neither window has data (free tier, or
# before the session's first API response) rather than shown with placeholder
# values.
seg_usage=""
if [ -n "$pct5" ] || [ -n "$pct7" ]; then
  rl_parts=""
  if [ -n "$pct5" ]; then
    e5=$(emoji_for_pct "$pct5")
    if [ -n "$resets5" ]; then
      rl_parts="${e5} 5h ${pct5}% ($(fmt_resets_phrase "$resets5"))"
    else
      rl_parts="${e5} 5h ${pct5}%"
    fi
  fi
  if [ -n "$pct7" ]; then
    [ -n "$rl_parts" ] && rl_parts="$rl_parts · "
    e7=$(emoji_for_pct "$pct7")
    if [ -n "$resets7" ]; then
      rl_parts="${rl_parts}${e7} 7d ${pct7}% ($(fmt_resets_phrase "$resets7"))"
    else
      rl_parts="${rl_parts}${e7} 7d ${pct7}%"
    fi
  fi
  seg_usage="$rl_parts"
fi

# Build the ordered list, skipping the usage segment when absent, and join
# with " | ". No trailing newline: keeps the renderer free to reflow the line.
segs=("$seg_cost")
[ -n "$seg_usage" ] && segs+=("$seg_usage")
segs+=("$seg_water" "$seg_context" "$seg_model" "$seg_turn")

line=""
for s in "${segs[@]}"; do
  if [ -z "$line" ]; then line="$s"; else line="$line | $s"; fi
done
printf '%s' "$line"
