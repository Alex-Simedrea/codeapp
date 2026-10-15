#!/usr/bin/env python3
"""Patch the downloaded Monaco bundle; keep SSH integration source in version control."""
from pathlib import Path
import shutil
import sys

asset = Path(sys.argv[1])
source = asset.read_text()


def replace_once(before, after):
    global source
    if after in source:
        return
    if source.count(before) != 1:
        raise SystemExit(f"Unsupported Monaco bundle: expected one {before[:90]!r}")
    source = source.replace(before, after, 1)


replace_once(
    'const msi=(n,e,t,i,s,o,r)=>{const a=new WebSocket(n);return ns.languageClientWebSocket=a,a.onopen=async()=>{a.send(JSON.stringify({args:e,redirectStderr:!1,workingDirectoryBookmark:i,isLanguageService:!0})),await new Promise(d=>setTimeout(d,2e3));const c=dsi(a),l=new qni(c),d=new tsi(c),h=bsi({reader:l,writer:d},s,hp(t),o,r);h.start(),l.onClose(()=>{gsi(s),h.stop()})},a}',
    'const msi=(n,e,t,i,s,o,r)=>{const remote=n.startsWith("codeapp-ssh:"),a=remote?window.codeAppRemoteLSP.createSocket(n):new WebSocket(n);return ns.languageClientWebSocket=a,a.onopen=async()=>{if(!remote){a.send(JSON.stringify({args:e,redirectStderr:!1,workingDirectoryBookmark:i,isLanguageService:!0}));await new Promise(d=>setTimeout(d,2e3))}if(a.readyState!==1)return;const c=dsi(a),l=new qni(c),d=new tsi(c),h=bsi({reader:l,writer:d},s,hp(t),o,r);h.start(),l.onClose(()=>{if(!remote)gsi(s);h.stop()})},a}')
replace_once(
    'clientOptions:{documentSelector:i??[e],initializationOptions:s??{},',
    'clientOptions:{documentSelector:window.codeAppRemoteLSP.documentSelector(t,i??[e],N0e),uriConverters:window.codeAppRemoteLSP.uriConverters(t,N0e),initializationOptions:s??{},')
# Accept resources previously patched before the content resolver was added.
source = source.replace('window.codeAppRemoteLSP.installNavigation(Qt.get(Ei),ns.editor)};Psi();', 'window.codeAppRemoteLSP.installNavigation(Qt.get(Ei),ns.editor,Qt.get(cs),Lc)};Psi();')
replace_once('Wsi(),J7(ns.editor)};Psi();',
             'Wsi(),J7(ns.editor),window.codeAppRemoteLSP.installNavigation(Qt.get(Ei),ns.editor,Qt.get(cs),Lc)};Psi();')
asset.write_text(source)
bundle = asset.parent.parent
shutil.copyfile(Path(__file__).parent / 'monaco/remote-lsp.js', bundle / 'remote-lsp.js')
index = bundle / 'index.html'
html = index.read_text()
if 'src="/remote-lsp.js"' not in html:
    html = html.replace('    <script type="module"', '    <script src="/remote-lsp.js"></script>\n    <script type="module"', 1)
    index.write_text(html)
