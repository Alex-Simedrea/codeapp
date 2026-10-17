# Embedded editor

These checked-in sources build the editor used by both app targets. Upstream and
its revision are recorded in UPSTREAM.md; npm dependencies are pinned in
package-lock.json. Node.js 20+ and npm are needed for a first build.

From the repository root:

```sh
scripts/build-monaco.sh
cd scripts/monaco-editor
npm exec tsc -- --noEmit
```

The build writes Resources/monaco-textmate.bundle. Native builds also invoke the
builder through patch-monaco-language-client.sh; unchanged sources reuse the
cached output. npm dependencies and generated resources are ignored by Git.
No edits to minified output are needed.

workspace.ts registers VS Code 6.0.3's AnythingQuickAccessProvider as the empty
prefix provider in the existing Quick Access palette. A child service collection
adapts its workspace, file search, filesystem metadata, history, editor, labels,
paths and dirty-working-copy services to MainApp/WorkSpaceStorage. The stock
provider retains fuzzy ranking, history grouping, cancellation and file:line:column
handling. The app continues to own tabs, permissions, SFTP connections and writes.
Commands (>), document symbols (@) and line navigation (:) use their existing
providers. The native app's editor.action.quickCommand entry point is preserved.

Requests use the existing WKScriptMessage channel, carry a workspace generation,
and support cancellation. Filename indexes are shared across queries, expire
after 30 seconds and are invalidated by workspace/file changes. Only filenames
are indexed; content is read on demand. SFTP indexing uses the attributes returned
by directory listings, avoiding a stat request per file. Symbolic directories
are not followed, to avoid cycles. File history is bounded and persisted per
workspace; opening a result activates existing dirty tabs without reloading disk.

remote-lsp.js and hardware-keyboard.js remain shared with their standalone tests.
The source build retains the SSH language client, native navigation and hardware
key-repeat integrations that previously patched the downloaded bundle.
