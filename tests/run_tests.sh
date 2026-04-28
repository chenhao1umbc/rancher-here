#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TMPDIR=""
FAILED=0
PASSED=0

cleanup() {
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
    if [[ -n "${MOCK_DIR:-}" && -d "$MOCK_DIR" ]]; then
        rm -rf "$MOCK_DIR"
    fi
}
trap cleanup EXIT

TMPDIR=$(mktemp -d)

# Create a mock claude command that records its arguments and exits with a given code
cat > "$TMPDIR/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$CLAUDE_ARGS_FILE"
exit "${CLAUDE_EXIT_CODE:-0}"
EOF
chmod +x "$TMPDIR/claude"

run_test() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS: $name"
        ((PASSED++)) || true
    else
        echo "FAIL: $name"
        ((FAILED++)) || true
    fi
}

# Test bin/ollama

echo "=== Testing bin/ollama ==="

run_test "ollama: intercepts 'launch claude'" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args1"
    "'$PROJECT_DIR'/bin/ollama" launch claude
    [[ -f "$CLAUDE_ARGS_FILE" ]] && [[ $(wc -l < "$CLAUDE_ARGS_FILE") -eq 1 ]] && [[ $(wc -c < "$CLAUDE_ARGS_FILE") -eq 1 ]]
'

run_test "ollama: passes remaining args" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args2"
    "'$PROJECT_DIR'/bin/ollama" launch claude --foo bar
    args=$(cat "$CLAUDE_ARGS_FILE")
    expected="--foo
bar"
    [[ "$args" == "$expected" ]]
'

run_test "ollama: rejects unsupported command" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args3"
    ! "'$PROJECT_DIR'/bin/ollama" pull llama3 > /dev/null 2>&1
'

run_test "ollama: rejects bare 'launch'" bash -c '
    export PATH="'$TMPDIR':$PATH"
    ! "'$PROJECT_DIR'/bin/ollama" launch > /dev/null 2>&1
'

run_test "ollama: rejects bare invocation" bash -c '
    export PATH="'$TMPDIR':$PATH"
    ! "'$PROJECT_DIR'/bin/ollama" > /dev/null 2>&1
'

run_test "ollama: rejects 'launch other'" bash -c '
    export PATH="'$TMPDIR':$PATH"
    ! "'$PROJECT_DIR'/bin/ollama" launch other > /dev/null 2>&1
'

# Test bin/ollaude

echo "=== Testing bin/ollaude ==="

run_test "ollaude: execs claude with no args" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args4"
    "'$PROJECT_DIR'/bin/ollaude"
    [[ -f "$CLAUDE_ARGS_FILE" ]] && [[ $(wc -l < "$CLAUDE_ARGS_FILE") -eq 2 ]] && [[ $(head -1 "$CLAUDE_ARGS_FILE") == "--model" ]] && [[ $(tail -1 "$CLAUDE_ARGS_FILE") == "kimi-k2.6:cloud" ]]
'

run_test "ollaude: passes args through" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args5"
    "'$PROJECT_DIR'/bin/ollaude" --version
    args=$(cat "$CLAUDE_ARGS_FILE")
    expected="--model
kimi-k2.6:cloud
--version"
    [[ "$args" == "$expected" ]]
'

run_test "ollaude: prepends --model kimi-k2.6:cloud" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args_model"
    "'$PROJECT_DIR'/bin/ollaude" --foo bar
    [[ $(head -1 "$CLAUDE_ARGS_FILE") == "--model" ]] && [[ $(sed -n 2p "$CLAUDE_ARGS_FILE") == "kimi-k2.6:cloud" ]]
'

run_test "ollaude: propagates exit code" bash -c '
    export PATH="'$TMPDIR':$PATH"
    export CLAUDE_ARGS_FILE="'$TMPDIR'/args6"
    export CLAUDE_EXIT_CODE=42
    "'$PROJECT_DIR'/bin/ollaude"; rc=$?
    [[ $rc -eq 42 ]]
'

# Test rancher-ollaude mount points

echo "=== Testing rancher-here mounts ==="

run_test "rancher-here: mounts bin directory" bash -c '
    grep -q "bin:/opt/ollama-wrappers" "'$PROJECT_DIR'/rancher-here"
'

run_test "rancher-here: mounts bin directory as ro" bash -c '
    grep -q "bin:/opt/ollama-wrappers:ro" "'$PROJECT_DIR'/rancher-here"
'

run_test "rancher-here: mounts rtk data dir" bash -c '
    grep -q "Library/Application Support/rtk:/home/agent/.local/share/rtk" "'$PROJECT_DIR'/rancher-here"
'

run_test "rancher-here: sets PATH with ollama-wrappers (rtk built-in)" bash -c '
    grep -q "PATH=/opt/ollama-wrappers:" "'$PROJECT_DIR'/rancher-here"
'

# Container integration tests

echo "=== Container integration tests ==="

if ! command -v nerdctl >/dev/null 2>&1; then
    echo "SKIP: nerdctl not installed"
elif ! nerdctl image inspect "claude-code:latest" >/dev/null 2>&1; then
    echo "SKIP: claude-code:latest image not found"
else
    MOCK_DIR=$(mktemp -d)
    cat > "$MOCK_DIR/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/claude"

    MOUNT_BIN="-v $PROJECT_DIR/bin:/opt/ollama-wrappers:ro"
    MOUNT_MOCK="-v $MOCK_DIR/claude:/home/agent/.local/bin/claude:ro"
    MOUNT_RTK_DATA="-v $HOME/Library/Application\ Support/rtk:/home/agent/.local/share/rtk"
    MOUNT_CLAUDE="-v $HOME/.claude:/home/agent/.claude-host:ro"
    PATH_OLLAMA="/opt/ollama-wrappers:/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    run_test "integration: ollama wrapper functions in container" bash -c '
        nerdctl run --rm \
            '"$MOUNT_BIN"' \
            '"$MOUNT_MOCK"' \
            -e "PATH='$PATH_OLLAMA'" \
            claude-code:latest \
            bash -c "ollama launch claude"
    '

    run_test "integration: ollaude wrapper functions in container" bash -c '
        nerdctl run --rm \
            '"$MOUNT_BIN"' \
            '"$MOUNT_MOCK"' \
            -e "PATH='$PATH_OLLAMA'" \
            claude-code:latest \
            bash -c "ollaude"
    '

    run_test "integration: ollama rejects unsupported command in container" bash -c '
        ! nerdctl run --rm \
            '"$MOUNT_BIN"' \
            '"$MOUNT_MOCK"' \
            -e "PATH='$PATH_OLLAMA'" \
            claude-code:latest \
            bash -c "ollama pull llama3" > /dev/null 2>&1
    '

    # RTK integration tests

    run_test "integration: rtk binary works in container" bash -c '
        nerdctl run --rm \
            claude-code:latest \
            bash -c "rtk --version | grep -q \"rtk 0.37.2\""
    '

    run_test "integration: rtk gain persists with data mount" bash -c '
        nerdctl run --rm \
            '"$MOUNT_RTK_DATA"' \
            claude-code:latest \
            bash -c "rtk gain 2>/dev/null | grep \"Total commands\" >/dev/null"
    '

    run_test "integration: rtk hook rewrites commands" bash -c '
        nerdctl run --rm \
            '"$MOUNT_CLAUDE"' \
            claude-code:latest \
            bash -c "echo '{\"tool_input\":{\"command\":\"git status\"}}' | rtk hook claude | grep -q 'hookEventName'"
    '

    rm -rf "$MOCK_DIR"
fi

# Shellcheck tests

echo "=== Shellcheck ==="

if command -v shellcheck >/dev/null 2>&1; then
    run_test "shellcheck: rancher-here" shellcheck -x "$PROJECT_DIR/rancher-here"
    run_test "shellcheck: bin/ollama" shellcheck "$PROJECT_DIR/bin/ollama"
    run_test "shellcheck: bin/ollaude" shellcheck "$PROJECT_DIR/bin/ollaude"
else
    echo "SKIP: shellcheck not installed"
fi

# Summary

echo ""
echo "========================"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
