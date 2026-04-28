# RTK Integration for rancher-ollaude

## Problem
RTK command rewriting worked inside the rancher-ollaude container, but token tracking data was ephemeral. Each container run showed "No tracking data yet" because RTK wrote to a local SQLite database that was discarded on `--rm`.

## Root Cause
The original `rancher-ollaude` script attempted to mount the host RTK binary:
```bash
-v "/opt/homebrew/bin/rtk:/opt/rtk/rtk:ro"
```

Single-file bind mounts from macOS host → Linux container via nerdctl/Lima often create an **empty directory** instead of a file. The container fell back to its built-in `/usr/local/bin/rtk` (installed by Dockerfile), which works for command rewriting but stores tracking data at `/home/agent/.local/share/rtk/history.db` — an ephemeral path lost on container exit.

## Solution
Replace the broken single-file binary mount with a **data directory mount**.

The container's built-in Linux RTK (v0.37.2) is fully compatible with the host's macOS SQLite database. By mounting the host's RTK data directory into the container, tracking persists across runs.

Changes to `rancher-ollaude`:

1. **Remove** the broken single-file binary mount:
   ```bash
   # REMOVED
   -v "/opt/homebrew/bin/rtk:/opt/rtk/rtk:ro" \
   ```

2. **Remove** `/opt/rtk` from PATH (no longer needed):
   ```bash
   # BEFORE
   -e "PATH=/opt/rtk:/opt/ollama-wrappers:..."
   # AFTER
   -e "PATH=/opt/ollama-wrappers:..."
   ```

3. **Add** the host RTK data directory mount:
   ```bash
   -v "$HOME/Library/Application Support/rtk:/home/agent/.local/share/rtk" \
   ```

## Verification
- `rtk --version` inside container returns `rtk 0.37.2` (built-in)
- `rtk gain` inside container shows persistent host tracking history
- Hook loads without warnings for both `claude` and `ollaude` workflows
- All 23 tests pass (including RTK integration tests)
- Shellcheck clean

## Files Modified
- `rancher-ollaude`: replaced broken binary mount with data directory mount, updated PATH
- `tests/run_tests.sh`: updated RTK integration tests to match new behavior
- `rtk_ollaude.md`: updated documentation
