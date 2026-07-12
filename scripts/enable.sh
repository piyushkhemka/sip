#!/usr/bin/env bash
#
# enable.sh — wire Sip 💧 into the main Claude Code status line.
#
# A plugin can auto-configure only the *subagent* status line; the main
# `statusLine` lives in the user's own settings. `sip.sh` is a single,
# self-contained file (only jq required), so this script INSTALLS a copy to a
# stable, location-independent path and points settings there:
#   ~/.claude/settings.json -> { "statusLine": { "type": "command",
#                                                 "command": "<stable>/sip.sh" } }
# That means the status line keeps working even if the source repo (or the
# versioned plugin cache dir) moves or is deleted. Re-run after updating the
# plugin to refresh the installed copy. Idempotent; backs up settings first.
#
# Usage:
#   scripts/enable.sh                    # install a stable copy, then wire it up
#   SIP_INPLACE=1 scripts/enable.sh      # point at the source file, no copy (dev)
#   SIP_DEST=/abs/x.sh scripts/enable.sh # override the install path
#   SIP_PATH=/abs/x.sh scripts/enable.sh # override the SOURCE script
#   CLAUDE_SETTINGS=/path.json scripts/enable.sh  # override target settings

set -euo pipefail

# --- Resolve the SOURCE sip.sh ----------------------------------------------
# Prefer an explicit override, then the installed plugin root, then this repo.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_SRC="$(cd "$SCRIPT_DIR/.." && pwd)/sip.sh"
SRC="${SIP_PATH:-${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/sip.sh}}"
SRC="${SRC:-$DEFAULT_SRC}"

# --- Stable install destination (location-independent) ----------------------
DEST="${SIP_DEST:-$HOME/.claude/sip.sh}"

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# If settings.json is a symlink (common with dotfiles managers like chezmoi,
# stow, yadm), write through it rather than replacing the symlink itself with
# a plain file — otherwise the user's settings silently fall out of dotfiles
# management. Only resolves one level (the common case for these tools).
if [ -L "$SETTINGS" ]; then
  link_target=$(readlink "$SETTINGS")
  case $link_target in
    /*) SETTINGS="$link_target" ;;
    *)  SETTINGS="$(cd "$(dirname "$SETTINGS")" && pwd)/$link_target" ;;
  esac
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq / apt-get install jq)" >&2
  exit 1
fi
if [ ! -f "$SRC" ]; then
  echo "error: source sip.sh not found at: $SRC" >&2
  exit 1
fi

# Install a stable copy unless the caller asked to run in place.
if [ "${SIP_INPLACE:-0}" = "1" ]; then
  COMMAND_PATH="$SRC"
  chmod +x "$SRC" 2>/dev/null || true
else
  mkdir -p "$(dirname "$DEST")"
  cp -f "$SRC" "$DEST"
  chmod +x "$DEST"
  COMMAND_PATH="$DEST"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"

# Back up, then merge the statusLine key (preserving all other settings). The
# backup suffix includes the PID (not just a 1-second-granularity timestamp):
# running this script twice within the same wall-clock second — e.g. a user
# re-running /sip-setup right after a mistake — would otherwise silently
# overwrite the first backup with the just-modified (no longer original)
# settings, making the documented ".bak" restore path lose the true original.
tmp="$SETTINGS.tmp.$$"
trap 'rm -f "$tmp" 2>/dev/null' EXIT
cp -f "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)-$$"

jq --arg cmd "$COMMAND_PATH" \
   '.statusLine = {type: "command", command: $cmd}' \
   "$SETTINGS" >"$tmp"
mv -f "$tmp" "$SETTINGS"

echo "✓ Sip status line set in $SETTINGS"
echo "  command: $COMMAND_PATH"
if [ "${SIP_INPLACE:-0}" != "1" ]; then
  echo "  (installed a stable copy — safe to move or delete the source repo)"
fi
echo "  Start or reload Claude Code to see it. To undo: remove the statusLine key or restore a .bak file."
