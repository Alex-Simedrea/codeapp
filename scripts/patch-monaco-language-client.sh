#!/usr/bin/env bash
set -euo pipefail

MONACO_ASSET=${1:-Resources/monaco-textmate.bundle/assets/index-CAlTf3CB.js}

# Build the checked-in editor sources, including VS Code's stock Go to File.
# The content hash avoids rebuilding unchanged JavaScript during native builds.
exec /bin/bash "$(dirname "$0")/build-monaco.sh" "$(dirname "$(dirname "$MONACO_ASSET")")"
