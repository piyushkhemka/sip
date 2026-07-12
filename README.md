# Sip 💧

Sip is a fun little project built around one question: **how much water does
it actually take to talk to Claude?** Every prompt takes a sip — literally.
Training and running LLMs consumes real water (datacenter cooling +
electricity generation), and that cost is normally invisible. Sip is a Claude
Code status line that puts a number on it, right where you're already
looking, updating live as you work.

```
💧 1.2 mL · 0.5 L today
```

That's the headline — this response's estimated water, then today's running
total. Sip also shows the useful stuff you'd want from a good
status line — session/daily cost, your 5-hour and weekly plan usage (with an
emoji so you know at a glance how close you are to a limit), context window
usage, model + effort, and your turn count. All local, all free, no extra API
calls:

```
💵 $0.42 ($3.17 today) | ⚠️ 5h 45% (resets in 2h14m) · ✅ 7d 12% (resets in 3d) | 💧 1.2 mL · 0.5 L today | 🧠 50k/200k (25%) | 🤖 opus 4.8 (high effort) | 🔄 Turn: 14
```

| Segment               | Shows                                                |
| --------------------- | ---------------------------------------------------- |
| 💵 **Cost**           | session cost + today's running total                 |
| ✅⚠️🚨🚫 **Usage**    | 5h / 7d plan usage, with a status emoji + reset time |
| 💧 **Water**          | estimated water this response · today's total        |
| 🧠 **Context**        | tokens used / window size, color-coded               |
| 🤖 **Model & effort** | short model name + reasoning effort                  |
| 🔄 **Turn**           | real user turns this session                         |

Usage status: ✅ `<33%` · ⚠️ `33–66%` · 🚨 `67–84%` · 🚫 `≥85%` (same
thresholds color the context segment). The usage segment only appears once
your account has rate-limit data — it's simply omitted otherwise, not shown
with placeholders.

> **On the context %:** Sip computes the percentage itself from the same raw
> token counts shown in `used/total` (input + cache, over the model's context
> window — 200k, or 1M on extended-context models) so the two can never
> visually disagree; it only falls back to Claude Code's own
> `context_window.used_percentage` if the window size isn't in the payload.
> This can still differ from other surfaces that exclude cache or use a
> different denominator. Set `SIP_DEBUG=/tmp/sip.log` to capture the exact
> payload Claude Code sends and see the raw numbers.

## Requirements

- `jq` (`brew install jq` on macOS, `apt-get install jq` on Debian/Ubuntu) and
  `awk` (present by default on macOS/Linux).
- Claude Code.

## Install

Two steps: **install the plugin**, then **run the setup command**. A plugin
can wire itself into the subagent panel automatically, but only you (via a
command) can point Claude Code's _main_ status line at it — that's a
one-time, Claude-Code-level setting.

### Step 1 — Install the plugin

From GitHub:

```bash
claude plugin marketplace add piyushkhemka/sip
claude plugin install sip
```

Or from a local checkout:

```bash
claude plugin marketplace add /path/to/sip
claude plugin install sip
```

This immediately wires up Sip's _subagent_ status line (visible in the agent
panel). Your main status line — the one at the bottom of the screen — isn't
set yet; that's step 2.

### Step 2 — Turn on the main status line

Inside Claude Code, run:

```
/sip-setup
```

This installs a stable, self-contained copy of `sip.sh` to `~/.claude/sip.sh`
and points your `~/.claude/settings.json` at it (backing up the current file
first). Because the installed copy is location-independent, Sip keeps working
even if the plugin's versioned cache directory changes on a later update —
just re-run `/sip-setup` after updating the plugin to refresh the copy.

Reload Claude Code and you'll see the status line at the bottom of the screen.

## Why it's cheap

Sip runs entirely locally and uses **zero API tokens** — nothing it shows,
including usage and water, costs you anything or counts against your plan.
The remaining cost is latency, so the script is built to minimize it:

- **One `awk` pass** over the session transcript counts real user turns and sums
  output tokens (for the water estimate) — the payload carries no turn number,
  so this keeps both accurate and idempotent. It's **skipped entirely** when the
  transcript hasn't grown since the last render (cached per session by byte
  size), which is the common case for repeated re-renders with no new messages.
- **One `jq` call** parses the payload, derives context/usage percentages, and
  does the daily cost + water bookkeeping (state read into the same call via
  `--slurpfile`), with every field defensively coerced so a malformed prior
  record can't corrupt the run.
- **One tiny atomic write** persists a single `daily.json` that self-resets when
  the local day changes — no per-day files, no cleanup. A lightweight
  `mkdir`-based lock (near-zero cost when uncontended) protects it from
  concurrent Claude Code sessions racing on the same file.
- Portable to the **bash 3.2** shipped on macOS; only requires `jq` and `awk`.

State lives in `${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.claude}/sip}/daily.json`,
alongside a small per-session transcript-scan cache.

## 💧 How the water estimate works

Sip turns the invisible cost of a response into a number, estimated **locally
from output tokens** (no network calls, still zero API tokens):

```
water_mL = output_tokens / 1000 × K        (default K = 1.5 mL per 1,000 output tokens)
```

Output tokens drive it because generation (decode) dominates inference energy;
input/prefill is far cheaper per token. The default **K = 1.5 mL / 1k output
tokens** is the _total_ footprint (cooling + electricity), derived transparently:

- **Energy:** ~0.3–0.6 Wh per 1k output tokens — consistent with Google's
  first-party figure of **0.24 Wh for a median Gemini text prompt** and GPU
  decode throughput.
- **Water intensity:** ~1.1 mL/Wh on-site (Google's implied WUE, PUE 1.09) plus
  ~2 mL/Wh for US grid electricity generation ≈ **~3 mL/Wh total**.
- ⇒ ~0.4–0.6 Wh × ~3 mL/Wh ≈ **~1.5 mL per 1k output tokens.**

Sanity: a typical response ≈ **1 mL**, a long one a few mL, a heavy day ~100–200
mL. That sits between Google's **0.26 mL** (on-site only) and the widely-shared
(and now debunked) **~500 mL "bottle per query"** figure, which was a large,
old GPT-3 worst case.

**This is an estimate, and the honest range is wide (~100×).** Tune it to your
own assumptions:

```bash
export SIP_WATER_ML_PER_1K_TOKENS=0.5   # conservative, on-site only (Google-scope)
export SIP_WATER_ML_PER_1K_TOKENS=1.5   # default, total footprint
```

Why not derive it from cost? Price embeds margin and varies by model tier, so
it's a noisier proxy for energy than tokens — Sip uses tokens.

Sources: [Google Cloud — measuring the environmental impact of AI inference (Aug 2025)](https://cloud.google.com/blog/products/infrastructure/measuring-the-environmental-impact-of-ai-inference)
· [Li et al., "Making AI Less Thirsty" (arXiv 2304.03271)](https://arxiv.org/pdf/2304.03271)
· [Goedecke, "Talking to ChatGPT costs 5ml of water, not 500ml"](https://www.seangoedecke.com/water-impact-of-ai/)

## 📊 Usage, at zero extra cost

The 5-hour and 7-day (weekly) percentages are the **same numbers `/usage`
shows you** — Claude Code already includes them in every status-line render
(`rate_limits.five_hour` / `rate_limits.seven_day`). Sip just reads them
locally and prints them; it makes **no extra API calls and adds nothing to
your usage** — checking your usage doesn't cost you usage.

Either window can be independently absent (e.g. only `five_hour` populated
yet); Sip shows whichever windows are present and omits the rest.

## Uninstall

- Remove the `statusLine` key from `~/.claude/settings.json` (or restore a
  `settings.json.bak.*` backup made by `enable.sh`).
- `claude plugin uninstall sip`.

## License

MIT — see [LICENSE](LICENSE).
