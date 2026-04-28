#!/bin/bash
# Entrypoint script for Claude Code container
# Builds an isolated .claude from the host read-only mount so the container
# never contends for file locks with the host Claude instance.
# Syncs session data back to the host after exit.

HOST_CLAUDE="/home/agent/.claude-host"
LOCAL_CLAUDE="/home/agent/.claude"
WRITEBACK="/home/agent/.claude-writeback"

mkdir -p "$LOCAL_CLAUDE"

# Copy .claude.json from host read-only mount so Claude has a writable copy
[ -f "/home/agent/.claude.json-host" ] && cp "/home/agent/.claude.json-host" "/home/agent/.claude.json"

# Copy config from host read-only mount
if [ -d "$HOST_CLAUDE" ]; then
    for f in settings.json settings.local.json CLAUDE.md history.jsonl; do
        [ -f "$HOST_CLAUDE/$f" ] && cp "$HOST_CLAUDE/$f" "$LOCAL_CLAUDE/$f"
    done

    [ -d "$HOST_CLAUDE/hooks" ] && cp -a "$HOST_CLAUDE/hooks" "$LOCAL_CLAUDE/hooks"
    [ -d "$HOST_CLAUDE/plugins" ] && cp -a "$HOST_CLAUDE/plugins" "$LOCAL_CLAUDE/plugins"
    [ -d "$HOST_CLAUDE/projects" ] && cp -a "$HOST_CLAUDE/projects" "$LOCAL_CLAUDE/projects"
    [ -d "$HOST_CLAUDE/scripts" ] && cp -a "$HOST_CLAUDE/scripts" "$LOCAL_CLAUDE/scripts"
    if [ -d "$HOST_CLAUDE/skills" ]; then
        mkdir -p "$LOCAL_CLAUDE/skills"
        cp -a "$HOST_CLAUDE/skills/." "$LOCAL_CLAUDE/skills/" 2>/dev/null || true
        ln -sf skills "$LOCAL_CLAUDE/commands"
        rm -rf "$LOCAL_CLAUDE/skills/skills" 2>/dev/null || true
    fi
fi

# Rewrite host paths to container paths in settings.json hooks
# (host HOME /Users/hc differs from container HOME /home/agent)
if [ -f "$LOCAL_CLAUDE/settings.json" ] && [ -n "${HOST_CLAUDE_DIR:-}" ]; then
    python3 -c "
import json, sys, os
host_dir = os.environ.get('HOST_CLAUDE_DIR', '')
path = '$LOCAL_CLAUDE/settings.json'
try:
    with open(path) as f:
        s = json.load(f)
except:
    sys.exit(0)
def rewrite(obj):
    if isinstance(obj, str):
        return obj.replace(host_dir, '/home/agent/.claude')
    if isinstance(obj, dict):
        return {k: rewrite(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite(i) for i in obj]
    return obj
s = rewrite(s)
with open(path, 'w') as f:
    json.dump(s, f, indent=2)
" 2>/dev/null
fi

# Rewrite fullPath in sessions-index.json files from host paths to container paths
# (host HOME /Users/hc differs from container HOME /home/agent)
for idx in "$LOCAL_CLAUDE/projects"/*/sessions-index.json; do
    [ -f "$idx" ] || continue
    python3 -c "
import json, re
with open('$idx') as f:
    d = json.load(f)
changed = False
for e in d.get('entries', []):
    fp = e.get('fullPath', '')
    new_fp = re.sub(r'^.*?/\.claude/', '/home/agent/.claude/', fp)
    if new_fp != fp:
        e['fullPath'] = new_fp
        changed = True
if changed:
    with open('$idx', 'w') as f:
        json.dump(d, f, indent=2)
" 2>/dev/null
done

# Fall back to built-in defaults if no settings found
if [ ! -f "$LOCAL_CLAUDE/settings.json" ]; then
    cp /opt/claude-defaults/settings.json "$LOCAL_CLAUDE/settings.json" 2>/dev/null || true
fi

# Run the command (not exec, so we can sync back after it exits)
"$@"
EXIT_CODE=$?

# Sync session data back to the host writable mount
if [ -d "$WRITEBACK/projects" ]; then
    for proj_dir in "$LOCAL_CLAUDE/projects"/*/; do
        [ -d "$proj_dir" ] || continue
        proj_name=$(basename "$proj_dir")
        host_proj="$WRITEBACK/projects/$proj_name"
        mkdir -p "$host_proj"

        # Copy new or larger .jsonl files (append-only, so larger = superset)
        for f in "$proj_dir"*.jsonl; do
            [ -f "$f" ] || continue
            target="$host_proj/$(basename "$f")"
            if [ ! -f "$target" ] || [ "$(stat -c%s "$f")" -gt "$(stat -c%s "$target")" ]; then
                cp "$f" "$target"
            fi
        done

        # Copy new session directories (sub-agent sessions)
        for d in "$proj_dir"*/; do
            [ -d "$d" ] || continue
            dname=$(basename "$d")
            case "$dname" in memory) continue ;; esac
            [ -d "$host_proj/$dname" ] || cp -r "$d" "$host_proj/$dname"
        done

        # Merge new entries into host's sessions-index.json
        container_index="$proj_dir/sessions-index.json"
        host_index="$host_proj/sessions-index.json"
        python3 -c "
import json, os, re, sys
from datetime import datetime, timezone

host_claude_dir = '${HOST_CLAUDE_DIR:-}'
proj_dir = '$proj_dir'
host_proj = '$host_proj'
container_index = '$container_index'
host_index = '$host_index'

# Load entries from container sessions-index.json if it exists
new_entries = []
orig_path = ''
indexed_sids = set()
if os.path.exists(container_index):
    try:
        container = json.load(open(container_index))
        new_entries = container.get('entries', [])
        orig_path = container.get('originalPath', '')
        indexed_sids = {e['sessionId'] for e in new_entries}
    except: pass

# Always scan for jsonl files not yet in the index (new sessions created this run)
for fname in os.listdir(proj_dir):
    if not fname.endswith('.jsonl'):
        continue
    fpath = os.path.join(proj_dir, fname)
    st = os.stat(fpath)
    session_id = fname[:-6]
    if session_id in indexed_sids:
        continue
    first_prompt = ''
    summary = ''
    message_count = 0
    created_ts = None
    modified_ts = None
    try:
        with open(fpath) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except:
                    continue
                t = e.get('type', '')
                sid = e.get('sessionId', '')
                if sid:
                    session_id = sid
                ts = e.get('timestamp')
                if ts:
                    if created_ts is None:
                        created_ts = ts
                    modified_ts = ts
                if t == 'user' and not first_prompt:
                    msg = e.get('message', {})
                    content = msg.get('content', '')
                    if isinstance(content, str):
                        first_prompt = content[:200]
                    elif isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'text':
                                first_prompt = c['text'][:200]
                                break
                if t in ('user', 'assistant'):
                    message_count += 1
                if t == 'summary':
                    summary = e.get('summary', '')[:200]
    except:
        continue
    if message_count == 0:
        continue
    if not created_ts:
        created_ts = datetime.fromtimestamp(st.st_ctime, tz=timezone.utc).isoformat()
    if not modified_ts:
        modified_ts = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat()
    new_entries.append({
            'sessionId': session_id,
            'fullPath': fpath,
            'fileMtime': int(st.st_mtime * 1000),
            'firstPrompt': first_prompt,
            'summary': summary,
            'messageCount': message_count,
            'created': created_ts,
            'modified': modified_ts,
            'gitBranch': '',
            'projectPath': orig_path,
            'isSidechain': False
        })

if not new_entries:
    sys.exit(0)

try:
    host = json.load(open(host_index))
except:
    host = {'version': 1, 'entries': [], 'originalPath': orig_path}
host_by_id = {e['sessionId']: i for i, e in enumerate(host.get('entries', []))}
for entry in new_entries:
    if host_claude_dir:
        fp = entry.get('fullPath', '')
        entry['fullPath'] = re.sub(r'^.*?/\.claude/', host_claude_dir + '/', fp)
        if not entry.get('projectPath'):
            entry['projectPath'] = host.get('originalPath', '')
    sid = entry['sessionId']
    if sid in host_by_id:
        idx = host_by_id[sid]
        if entry.get('modified', '') >= host['entries'][idx].get('modified', ''):
            host['entries'][idx] = entry
    else:
        host['entries'].append(entry)
json.dump(host, open(host_index, 'w'), indent=2)
" 2>/dev/null
    done
fi

# Stage .claude.json project updates for rancher-here to merge after exit
if [ -d "$WRITEBACK" ] && [ -f "/home/agent/.claude.json" ]; then
    cp /home/agent/.claude.json "$WRITEBACK/.claude.json.sync" 2>/dev/null
fi

# Sync settings.local.json back to host (captures model selection and user preferences)
if [ -d "$WRITEBACK" ] && [ -f "$LOCAL_CLAUDE/settings.local.json" ]; then
    cp "$LOCAL_CLAUDE/settings.local.json" "$WRITEBACK/settings.local.json" 2>/dev/null
fi

# Sync model key from settings.json back to host (in case model is stored there)
if [ -d "$WRITEBACK" ] && [ -f "$LOCAL_CLAUDE/settings.json" ] && [ -f "$WRITEBACK/settings.json" ]; then
    python3 -c "
import json, sys
try:
    with open('$LOCAL_CLAUDE/settings.json') as f:
        container = json.load(f)
    model = container.get('model')
    if model is None:
        sys.exit(0)
    with open('$WRITEBACK/settings.json') as f:
        host = json.load(f)
    if host.get('model') == model:
        sys.exit(0)
    host['model'] = model
    with open('$WRITEBACK/settings.json', 'w') as f:
        json.dump(host, f, indent=2)
except: pass
" 2>/dev/null
fi

# Append new history entries back to host (deduplicated by sessionId+timestamp)
if [ -d "$WRITEBACK" ] && [ -f "$LOCAL_CLAUDE/history.jsonl" ]; then
    python3 -c "
import json, sys
host_path = '$WRITEBACK/history.jsonl'
container_path = '$LOCAL_CLAUDE/history.jsonl'
existing = set()
try:
    with open(host_path) as f:
        for line in f:
            try:
                e = json.loads(line)
                existing.add((e.get('sessionId', ''), e.get('timestamp', 0)))
            except: pass
except FileNotFoundError: pass
new_lines = []
with open(container_path) as f:
    for line in f:
        try:
            e = json.loads(line)
            if (e.get('sessionId', ''), e.get('timestamp', 0)) not in existing:
                new_lines.append(line)
        except: pass
if new_lines:
    with open(host_path, 'a') as f:
        for line in new_lines:
            f.write(line if line.endswith('\n') else line + '\n')
" 2>/dev/null
fi

exit $EXIT_CODE
