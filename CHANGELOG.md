# Changelog

All notable changes to Sip are documented here. This project
adheres to [Semantic Versioning](https://semver.org).

## [0.3.3] - 2026-07-10

Fixes from a second adversarial code review (1 critical), plus a self-audit
that found and fixed a display bug and several documentation inaccuracies.

### Fixed

- **[Critical]** A malformed/truncated stdin payload — or an invalid
  `SIP_WATER_ML_PER_1K_TOKENS` value like `"."` that slipped past validation
  and made `jq --argjson` fail — caused the state-file failure/retry path to
  reset `daily.json` to `{}`, silently destroying every other session's
  tracked daily cost and water total for the day. The reset is now decoupled
  from the main jq run entirely: `daily.json`'s own JSON validity is checked
  independently _before_ the one real jq call, and only ever reset if it
  itself is unparseable. If the main jq run still fails afterward (bad
  payload, bad argument), the state file is left untouched and the display
  degrades gracefully via existing fallbacks instead.
- Tightened `SIP_WATER_ML_PER_1K_TOKENS` validation to reject malformed
  decimals (`.`, `1.`, `.5`, `1.2.3`) that previously passed the character-set
  check but weren't valid JSON numbers, which was the second trigger for the
  bug above.
- **Water amount formatting** — jq silently drops a trailing `.0` (`1.0`
  prints as `"1"`), so the same field could inconsistently show `1 mL` next
  to `12.9 mL`. A new `fmt1dp` helper guarantees exactly one decimal digit
  always, for both the per-response mL figure and the daily liters figure.
- **README accuracy**: the intro's water example didn't match the actual
  segment output format; the context-% explanation described pre-fix
  behavior (said Sip passes through Claude Code's `used_percentage` directly,
  when it's actually derived locally from the same raw token counts as
  `used/total`, with `used_percentage` only as a fallback); the "why it's
  cheap" section didn't mention that the single `jq` call also handles the
  usage/rate-limit segment; a context-% callout was misplaced under the
  "Usage" (rate-limit) section heading instead of near the context segment.
- `marketplace.json`'s plugin description was stale — it was never updated
  when `plugin.json`'s description changed in 0.3.1.

## [0.3.2] - 2026-07-09

### Fixed

- Usage segment reset time was ambiguous — `(3h50m)` didn't say whether that
  was time elapsed or time remaining. Now reads `(resets in 3h50m)`; the past
  case reads `(resets now)` rather than the ungrammatical `resets in now`.

## [0.3.1] - 2026-07-09

### Changed

- **Segment order**: cost → usage → water → context → model → turn (water and
  usage moved up, ahead of context/model/turn).
- **Usage segment** now leads with a status emoji per window instead of a
  static 📊 label: ✅ `<33%` · ⚠️ `33–66%` · 🚨 `67–84%` · 🚫 `≥85%` — the same
  thresholds already used to color-code the context segment. The percentage
  itself is no longer separately color-coded (the emoji is the signal).
- **README rewritten** to lead with the fun/viral framing (why the project
  exists, the water number front and center) followed by a terse description
  of the rest, then install, then "Why it's cheap." Removed the "Without the
  plugin system" and "Try it without Claude Code" sections.

## [0.3.0] - 2026-07-09

### Added

- **📊 Rate-limit usage segment** — shows the 5-hour and 7-day (weekly) Pro/Max
  plan usage percentages and time until each resets, e.g.
  `📊 5h 23% (2h14m) · 7d 41% (3d)`. Sourced from the payload's `rate_limits`
  field (the same data `/usage` shows), so it costs no extra API calls and adds
  nothing to usage. Color-coded with the same thresholds as the context segment.
  Either window is shown independently and the whole segment is omitted (not
  shown with placeholders) when neither is present — e.g. free tier, or before
  the session's first API response.

### Changed

- README rewritten for clarity: install is now two explicit, numbered steps
  (install the plugin, then run `/sip-setup`), with a separate section for
  using Sip without the plugin system. Full repo audit confirms no bare
  "statusline" wording remains anywhere — only Claude Code's own required
  `statusLine`/`subagentStatusLine` settings keys, which are its API, not ours.
- `plugin.json` keywords: dropped the bare `statusline` keyword (kept the
  hyphenated `status-line`, matching how Claude Code's own docs describe the
  feature in prose).

## [0.2.1] - 2026-07-08

Fixes from an adversarial code review (1 critical, 3 high, 3 medium, 2 low).

### Fixed

- **[Critical]** `sip.sh` display fields are now joined with the ASCII unit
  separator (`\x1f`) instead of a tab. Bash's `IFS=$'\t' read` treats tab as
  "IFS whitespace" and collapses/drops empty fields, which silently misaligned
  every field after an empty one — e.g. an empty `effort.level` or an
  unrecognized `model.id` with no `display_name` shifted cost, model, and
  effort, and permanently zeroed the turn counter with no visible error.
- **[High]** The state-file failure/retry path no longer wipes every other
  session's daily cost and water total on an ordinary jq type error (e.g. a
  non-numeric `cost.total_cost_usd`, or one malformed prior session record).
  All state fields are now defensively coerced to numbers so the reset path is
  reserved for a genuinely unparseable state file.
- **[High]** Concurrent Sip renders (multiple Claude Code sessions writing
  `daily.json` at once) could silently drop one session's cost/water update.
  Added a lightweight `mkdir`-based lock (near-zero cost when uncontended,
  bounded retries with stale-lock takeover, fails open rather than hanging).
- **[High]** `scripts/enable.sh`'s settings backup filename had 1-second
  granularity; running it twice in the same second overwrote the first backup
  with already-modified settings, silently losing the true original. Backup
  filenames now include the PID.
- **[Medium]** The context-usage percentage is now derived from the same raw
  token counts as the displayed `used/total` fraction, so they can never
  visually contradict each other (falls back to the payload's own
  `used_percentage` only when `context_window_size` is absent).
- **[Medium]** The turn counter's `tool_result` exclusion now matches the JSON
  structural marker `"type":"tool_result"` instead of the bare word, so a user
  prompt that merely mentions "tool_result" in prose is no longer miscounted.
- **[Medium]** `scripts/enable.sh` now writes through a symlinked
  `settings.json` (common with dotfiles managers) instead of replacing the
  symlink with a plain file.
- **[Low]** `sip.sh` no longer depends on jq's `strflocaltime` (jq >= 1.6
  only); today's date is computed once in bash and passed in, which also
  removes a portability failure mode on older jq builds.
- **[Low]** `scripts/enable.sh` cleans up its temp file via a trap if `jq`
  fails partway through.
- **[Low]** The transcript `awk` invocation now uses `--` before the path
  argument (defense in depth).

### Added

- The transcript scan is now cached per session (byte size + counts in a
  small sidecar file) and skipped entirely when the transcript hasn't grown
  since the last render — the common case for repeated re-renders with no new
  messages — reducing latency on long-running sessions with large transcripts.

## [0.2.0] - 2026-07-08

### Added

- **💧 Water segment** — estimates the water consumed (datacenter cooling +
  electricity generation) per response and cumulatively today, shown as
  `💧 <resp> · <daily> today`. Derived locally from output tokens:
  `water_mL = output_tokens / 1000 × K`, default **K = 1.5 mL / 1k output
  tokens** (total footprint), tunable via `SIP_WATER_ML_PER_1K_TOKENS`.
- The transcript `awk` pass now also sums assistant `output_tokens` (session
  total + last response), so per-response and daily water are accurate and
  idempotent. Daily water aggregates across sessions like daily cost.
- README section documenting the estimate's derivation, sources, and the honest
  ~100× uncertainty range.

## [0.1.0] - 2026-07-08

### Added

- Initial release of **Sip 💧** — _"Every prompt takes a sip."_
- `sip.sh`: a four-segment Claude Code status line —
  - 💵 session + daily cost (`cost.total_cost_usd`, aggregated locally),
  - 🧠 color-coded context usage (`context_window.used_percentage`),
  - 🤖 short model name + reasoning effort,
  - 🔄 real user-turn count, read from the session transcript.
- Low-overhead by design: one `jq` process (payload parse + daily-cost
  bookkeeping via `--slurpfile`) plus one `awk` pass for the turn count, then a
  single atomic write to `daily.json` (self-resets daily). Portable to bash 3.2.
- `SIP_DEBUG=/path/to/log` captures the raw payload Claude Code sends.
- Plugin packaging: `plugin.json` manifest, single-plugin `marketplace.json`,
  and a bundled `settings.json` that wires the subagent status line.
- `/sip-setup` command and `scripts/enable.sh` install a stable,
  location-independent copy to `~/.claude/sip.sh` and wire the main `statusLine`
  into `~/.claude/settings.json` idempotently, with backup.
