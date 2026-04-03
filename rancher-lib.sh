#!/bin/bash
# Shared utilities for rancher-* scripts.
# Source this file after setting CLAUDE_DIR.

IMAGE_NAME="claude-code:latest"
CURRENT_DIR="$(pwd)"

# Safety check - exit if in a dangerous directory
case "$CURRENT_DIR" in
  /|/usr|/usr/*|/bin|/sbin|/etc|/var|/sys|/proc|/dev|/home|/Users|/System*|/Library*)
    echo "Error: Cannot run in system directory: $CURRENT_DIR"
    echo "This is a safety measure to prevent accidental system modifications."
    exit 1
    ;;
  "$HOME"|"$HOME/")
    echo "Warning: Running in home directory: $CURRENT_DIR"
    read -p "This gives Claude access to your entire home directory. Continue? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    ;;
esac

rancher_ensure_image() {
  if ! nerdctl image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Building image (this may take a minute)..."
    if nerdctl build --build-arg HOST_UID=$(id -u) -t "$IMAGE_NAME" -f Dockerfile "$CLAUDE_DIR" >/dev/null 2>&1; then
      echo "Image built successfully"
    else
      echo "Build failed"
      exit 1
    fi
  fi
}

# Once per new host version per day: update host claude, sync container version, update plugins.
# Cache format: DATE:HOST_VERSION:CONTAINER_VERSION
rancher_version_check() {
  local cache_file="$CLAUDE_DIR/.last-version-check"
  local host_version today cached cached_date cached_host cached_container
  host_version=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  today=$(date +%Y%m%d)
  cached=$(cat "$cache_file" 2>/dev/null)
  IFS=: read -r cached_date cached_host cached_container <<< "$cached"

  [ "$today" = "$cached_date" ] && [ "$host_version" = "$cached_host" ] && return

  echo "Checking for Claude updates..."
  claude update < /dev/null || true
  host_version=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  # Use cached container version if available; otherwise spin up a container to read it
  local container_version="${cached_container:-$(nerdctl run --rm "$IMAGE_NAME" bash -c "export PATH=/home/agent/.local/bin:\$PATH && claude --version 2>/dev/null" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)}"

  if [ -n "$host_version" ] && [ -n "$container_version" ] && [ "$host_version" != "$container_version" ]; then
    echo "Rebuilding container ($container_version -> $host_version)..."
    if nerdctl build --build-arg HOST_UID=$(id -u) --build-arg CLAUDE_CODE_VERSION="$(date +%s)" -t "$IMAGE_NAME" -f Dockerfile "$CLAUDE_DIR" >/dev/null 2>&1; then
      echo "Container updated to $host_version"
      container_version="$host_version"
    else
      echo "Rebuild failed, continuing with old version"
    fi
  fi

  local plugin_json
  plugin_json=$(CLAUDECODE= claude plugin list --json 2>/dev/null)
  if [ -n "$plugin_json" ]; then
    echo "Updating plugins..."
    pids=()
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      CLAUDECODE= claude plugin update "$name" 2>/dev/null &
      pids+=($!)
    done < <(echo "$plugin_json" | python3 -c "
import json, sys
try:
    for p in json.load(sys.stdin):
        print(p.get('name', ''))
except: pass
" 2>/dev/null)
    for pid in "${pids[@]}"; do wait "$pid" || true; done
  fi

  echo "$today:$host_version:$container_version" > "$cache_file"
}

rancher_get_oauth_token() {
  OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null)
  if [ -z "$OAUTH_TOKEN" ]; then
    echo "Warning: Could not extract Claude OAuth token from Keychain. You may need to log in."
  fi
}

rancher_it_flag() {
  IT_FLAG=""
  [ -t 0 ] && IT_FLAG="-it"
}

rancher_sync_claude_json() {
  local sync_file="$HOME/.claude/.claude.json.sync"
  [ -f "$sync_file" ] || return
  python3 -c "
import json, sys
try:
    with open('$sync_file') as f:
        container = json.load(f)
    with open('$HOME/.claude.json') as f:
        host = json.load(f)
except: sys.exit(0)
cp = container.get('projects', {})
hp = host.get('projects', {})
changed = False
for path, data in cp.items():
    csid = data.get('lastSessionId', '')
    if not csid:
        continue
    if path not in hp:
        hp[path] = {}
    hsid = hp[path].get('lastSessionId', '')
    if csid != hsid:
        hp[path]['lastSessionId'] = csid
        changed = True
    for k in ['lastCost','lastAPIDuration','lastDuration','lastLinesAdded',
               'lastLinesRemoved','lastTotalInputTokens','lastTotalOutputTokens',
               'lastModelUsage','lastSessionMetrics']:
        if k in data:
            hp[path][k] = data[k]
            changed = True
if changed:
    with open('$HOME/.claude.json', 'w') as f:
        json.dump(host, f, indent=2)
" 2>/dev/null
  rm -f "$sync_file"
}
