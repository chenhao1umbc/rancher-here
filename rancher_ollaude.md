# rancher-ollaude: Technical Reference

## Overview
`rancher-ollaude` is a thin bash wrapper around the existing `rancher-here` toolchain. It routes Claude Code API calls through the host Ollama server (`host.lima.internal:11434`) instead of the Anthropic cloud, enabling the use of cloud models like `kimi-k2.6:cloud` inside a containerized environment.

## Architecture
```
Host (macOS)
├── rancher-ollaude (wrapper script)
├── rancher-lib.sh (shared functions, sourced)
├── bin/
│   ├── ollama (intercepts "ollama launch claude")
│   └── ollaude (execs claude with --model kimi-k2.6:cloud)
├── /opt/homebrew/bin/rtk (RTK binary)
└── host.lima.internal:11434 (Ollama proxy)

Container (nerdctl/Lima)
├── /opt/ollama-wrappers/ollama (mounted from host bin/ollama)
├── /opt/ollama-wrappers/ollaude (mounted from host bin/ollaude)
├── /opt/rtk/rtk (mounted from host RTK binary)
├── ~/.claude-host/hooks/rtk-rewrite.sh (mounted from host)
└── claude (calls routed to Ollama via env vars)
```

## Key Environment Variables Passed to Container
- `ANTHROPIC_BASE_URL=http://host.lima.internal:11434` — routes API calls to host Ollama
- `ANTHROPIC_AUTH_TOKEN=ollama` — Ollama auth token
- `ANTHROPIC_API_KEY=` — empty to disable Anthropic cloud key
- `PATH=/opt/rtk:/opt/ollama-wrappers:...` — makes wrapper scripts and RTK callable by name

## Bug 1: "ollaude: command not found" Inside Container

### Symptom
Running `ollaude` inside an interactive container shell returned:
```
bash: ollaude: command not found
```

### Root Cause
Individual file mounts to non-existent container paths can be flaky in nerdctl/Lima. The runtime may create a directory instead of a file mount, yielding "command not found".

Original approach (broken):
```bash
-v "$CLAUDE_DIR/bin/ollama:/usr/local/bin/ollama:ro" \
-v "$CLAUDE_DIR/bin/ollaude:/usr/local/bin/ollaude:ro" \
```

### Fix
Mount the entire `bin/` directory to `/opt/ollama-wrappers:ro` and explicitly set `PATH` to include it:
```bash
-v "$CLAUDE_DIR/bin:/opt/ollama-wrappers:ro" \
-e "PATH=/opt/ollama-wrappers:/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
```

This avoids single-file mount flakiness by relying on directory mounts, which are more reliable in nerdctl/Lima.

## Bug 2: "ollaude" Launches Sonnet 4.6 Instead of kimi-k2.6:cloud

### Symptom
Running `ollaude` inside the container showed:
```
[Sonnet 4.6] | ollaude
```

### Root Cause (Two-Layer)

**Layer 1: Missing --model flag**
The `bin/ollaude` wrapper script originally had:
```bash
exec claude "$@"
```
This fell back to the default model (`claude-sonnet-4-6`).

**Layer 2: PATH copy drift**
The `rancher-ollaude` script in `/Users/hc/Documents/research/rancher/` (the PATH location) was an older version. When the user ran `rancher-ollaude` from PATH, it mounted its own stale `bin/` into the container, overriding the project `bin/`.

### Fix
1. Updated `bin/ollaude` to pass `--model kimi-k2.6:cloud`:
   ```bash
   exec claude --model kimi-k2.6:cloud "$@"
   ```

2. Synced the PATH copy `/Users/hc/Documents/research/rancher/bin/ollaude` to match the project `bin/ollaude`.

## Bug 3: RTK Hook Not Working Inside Container

See `rtk_ollaude.md` for details.

## Testing
All verification is in `tests/run_tests.sh`:
- Unit tests for `bin/ollama` and `bin/ollaude`
- Mount verification tests for `rancher-ollaude`
- Container integration tests (ollama/ollaude wrappers, RTK)
- Shellcheck validation

Run: `./tests/run_tests.sh`

## Constraints Respected
- Zero changes to `rancher-here`, `rancher-lib.sh`, `Dockerfile`, `entrypoint.sh`, `compose.yml`
- `rancher-here` continues to work exactly as before
- Shellcheck clean for all new/modified scripts
