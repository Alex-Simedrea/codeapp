#!/usr/bin/env bash
set -euo pipefail

MONACO_ASSET=${1:-Resources/monaco-textmate.bundle/assets/index-CAlTf3CB.js}

if [ ! -f "$MONACO_ASSET" ]; then
  echo "error: Monaco client asset not found: $MONACO_ASSET" >&2
  exit 1
fi

perl -0pi -e 's|,window\.webkit\.messageHandlers\.toggleMessageHandler\.postMessage\(\{Event:"Language Server Debug",message:"launch request sent",readyState:a\.readyState,languageIdentifier:s\}\)||g' "$MONACO_ASSET"

if grep -q 'const msi=(n,e,t,i,s,o,r)=>' "$MONACO_ASSET"; then
  exit 0
fi

perl -0pi -e 's|const msi=\(n,e,t,i,s\)=>\{const o=new WebSocket\(n\);return ns\.languageClientWebSocket=o,o\.onopen=async\(\)=>\{o\.send\(JSON\.stringify\(\{args:e,redirectStderr:!1,workingDirectoryBookmark:i,isLanguageService:!0\}\)\),await new Promise\(d=>setTimeout\(d,2e3\)\);const r=dsi\(o\),a=new qni\(r\),c=new tsi\(r\),l=bsi\(\{reader:a,writer:c\},s,hp\(t\)\);l\.start\(\),a\.onClose\(\(\)=>\{gsi\(s\),l\.stop\(\)\}\)\},o\},bsi=\(n,e,t\)=>new Oni\(\{name:"Sample Language Client",clientOptions:\{documentSelector:\[e\],|const msi=(n,e,t,i,s,o,r)=>{const a=new WebSocket(n);return ns.languageClientWebSocket=a,a.onopen=async()=>{a.send(JSON.stringify({args:e,redirectStderr:!1,workingDirectoryBookmark:i,isLanguageService:!0})),await new Promise(d=>setTimeout(d,2e3));const c=dsi(a),l=new qni(c),d=new tsi(c),h=bsi({reader:l,writer:d},s,hp(t),o,r);h.start(),l.onClose(()=>{gsi(s),h.stop()})},a},bsi=(n,e,t,i,s)=>new Oni({name:"Sample Language Client",clientOptions:{documentSelector:i??[e],initializationOptions:s??{},|' "$MONACO_ASSET"

if ! grep -q 'const msi=(n,e,t,i,s,o,r)=>' "$MONACO_ASSET"; then
  echo "error: Monaco language client patch did not apply" >&2
  exit 1
fi
