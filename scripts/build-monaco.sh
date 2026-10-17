#!/usr/bin/env bash
set -euo pipefail
export PATH="${NODE_BINARY:+$(dirname "$NODE_BINARY"):}/opt/homebrew/bin:/usr/local/bin:$PATH"
SCRIPT_ROOT=$(cd "$(dirname "$0")" && pwd)
EDITOR_SOURCE="$SCRIPT_ROOT/monaco-editor"
DESTINATION=${1:-"$SCRIPT_ROOT/../Resources/monaco-textmate.bundle"}
# Dependencies are installed once by downloadFrameworks.sh or an explicit source build.
LOCK_HASH=$(shasum -a 256 "$EDITOR_SOURCE/package-lock.json" | cut -d ' ' -f 1)
if [ ! -x "$EDITOR_SOURCE/node_modules/.bin/vite" ] || [ ! -f "$EDITOR_SOURCE/node_modules/.codeapp-lock" ] || [ "$(cat "$EDITOR_SOURCE/node_modules/.codeapp-lock")" != "$LOCK_HASH" ]; then
  (cd "$EDITOR_SOURCE" && npm ci --ignore-scripts --no-audit --no-fund)
  printf '%s' "$LOCK_HASH" > "$EDITOR_SOURCE/node_modules/.codeapp-lock"
fi
SOURCE_HASH=$(python3 - "$EDITOR_SOURCE" "$SCRIPT_ROOT/monaco" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
for root in map(pathlib.Path, sys.argv[1:]):
    for p in sorted(root.rglob('*')):
        if p.is_file() and not any(x in p.parts for x in ('node_modules', 'monaco-textmate.bundle')) and p.suffix in ('.ts', '.js', '.json', '.html', '.css'):
            h.update(str(p.relative_to(root)).encode()); h.update(p.read_bytes())
print(h.hexdigest())
PY
)
OUTPUT="$EDITOR_SOURCE/monaco-textmate.bundle"
if [ ! -f "$OUTPUT/.codeapp-source-build" ] || [ "$(cat "$OUTPUT/.codeapp-source-build")" != "$SOURCE_HASH" ]; then
  (cd "$EDITOR_SOURCE" && ./node_modules/.bin/vite build)
  cp "$SCRIPT_ROOT/monaco/remote-lsp.js" "$OUTPUT/remote-lsp.js"
  cp "$SCRIPT_ROOT/monaco/hardware-keyboard.js" "$OUTPUT/hardware-keyboard.js"
  printf '%s' "$SOURCE_HASH" > "$OUTPUT/.codeapp-source-build"
fi
mkdir -p "$DESTINATION"
# Keep downloaded ancillary resources, replacing the entry point and generated assets.
cp -R "$OUTPUT/." "$DESTINATION/"
