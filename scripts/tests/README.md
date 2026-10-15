# Remote C/C++ language service checks

Run from the repository root after downloading the resources and applying
`scripts/patch-monaco-language-client.sh`.

```sh
swiftc CodeApp/Managers/LanguageServerProtocol.swift scripts/tests/LanguageServerProtocolTests.swift -o /tmp/codeapp-lsp-tests
/tmp/codeapp-lsp-tests
npm install --prefix /tmp/codeapp-lsp-tools --no-audit --no-fund vscode-uri playwright
NODE_PATH=/tmp/codeapp-lsp-tools/node_modules node scripts/tests/remote-lsp.test.cjs
NODE_PATH=/tmp/codeapp-lsp-tools/node_modules node scripts/tests/remote-lsp-integration.cjs
```

The integration check uses the actual bundled Monaco language client and a real
local clangd process behind the native bridge contract. It needs Python 3,
`/usr/bin/clangd` and Chrome; set `CHROME_EXECUTABLE` for a different Chrome path.
It verifies initialization with remote paths, unsaved diagnostics, project-symbol
completion and cross-file navigation. It writes failure details and a screenshot
to `/tmp/codeapp-lsp-browser*`. A known pre-existing `Promise.all` startup error
in the downloaded Monaco bundle is excluded from this check.

For a device check, build the `Code App` scheme and install it on an iPad. Connect
using an SSH shortcut, open a remote folder with C/C++ sources and a
`compile_commands.json`, and open a `.c` file. Check unsaved errors/warnings,
completion/inline preview, hover, and Go to Definition into an unopened file.
Switch between a source and header and verify that the same remote clangd
process stays running. Disable **C/C++ over SSH**, disconnect SSH, or switch to a
local folder and verify that the remote process exits and its diagnostics clear.
If clangd is absent from the host's SSH PATH, expect one warning; there is no
local fallback for remote files. Toggle the service to retry after installing it.
