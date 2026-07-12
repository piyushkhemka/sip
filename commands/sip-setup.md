---
name: sip-setup
description: Enable the Sip main status line by wiring it into your ~/.claude/settings.json.
---

# Set up Sip 💧

Wire this plugin's `sip.sh` into the user's main Claude Code status line.

Steps:

1. Determine the absolute path to the plugin's `sip.sh`. If the
   `CLAUDE_PLUGIN_ROOT` environment variable is available, it is
   `${CLAUDE_PLUGIN_ROOT}/sip.sh`. Otherwise locate the installed
   plugin directory (it contains `sip.sh` and `.claude-plugin/plugin.json`).

2. Run the bundled setup script. It installs a stable, self-contained copy of
   `sip.sh` to `~/.claude/sip.sh` and idempotently sets the `statusLine`
   key in `~/.claude/settings.json` to point there (backing up the current file
   first). Because the copy is location-independent, the status line keeps
   working even if the plugin's versioned cache directory changes on update —
   just re-run this command after updating to refresh the copy.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}"/scripts/enable.sh
   ```

   If `CLAUDE_PLUGIN_ROOT` is not set, run `scripts/enable.sh` from the plugin
   directory, or pass the path explicitly:

   ```bash
   SIP_PATH="/abs/path/to/sip.sh" /abs/path/to/scripts/enable.sh
   ```

3. Confirm the result to the user and tell them to reload Claude Code (the
   status line refreshes on the next interaction). Report the exact `command`
   path that was written.

To remove it later, delete the `statusLine` key from `~/.claude/settings.json`
or restore one of the `settings.json.bak.*` backups the script created.
