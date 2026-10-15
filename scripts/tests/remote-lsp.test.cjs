const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
// Resolve from the test runner's dependencies; production adds no npm dependency.
const { URI } = require('vscode-uri');
const posted = [];
const window = { webkit: { messageHandlers: { toggleMessageHandler: { postMessage: m => posted.push(m) } } } };
vm.runInNewContext(fs.readFileSync('scripts/monaco/remote-lsp.js', 'utf8'), {
    window, queueMicrotask, setTimeout, clearTimeout, crypto: require('node:crypto').webcrypto
});
(async () => {
    const api = window.codeAppRemoteLSP;
    const root = 'sftp://user@[2001:db8::1]:2222/home/project%20one';
    const converters = api.uriConverters(root, URI);
    for (const path of ['/home/project one/main.c', '/usr/include/stdio.h', '/tmp/café #1/100%.h']) {
        const remote = URI.parse(root).with({ path });
        const file = URI.file(path);
        assert.equal(converters.code2Protocol(remote), file.toString());
        assert.equal(converters.protocol2Code(file.toString()).toString(), remote.toString());
    }
    assert.equal(converters.code2Protocol(URI.file(URI.parse(root).path)), URI.file(URI.parse(root).path).toString());
    assert.throws(() => converters.code2Protocol(URI.file('/private/local.c')));
    assert.throws(() => converters.code2Protocol(URI.parse('sftp://other:22/main.c')));
    assert.equal(api.uriConverters('file:///tmp/project', URI), undefined);
    assert.equal(converters.protocol2Code('https://clangd.llvm.org').scheme, 'https');
    const selectors = api.documentSelector(root, ['c', 'cpp'], URI);
    assert.deepEqual(Array.from(selectors, s => [s.language, s.scheme]), [['c','sftp'], ['cpp','sftp']]);
    assert.deepEqual(api.documentSelector('file:///tmp/project', ['c'], URI), ['c']);
    const socket = api.createSocket('codeapp-ssh:test-connection');
    let opened = 0, closed = 0, received;
    socket.onopen = () => opened++;
    socket.onclose = () => closed++;
    socket.onmessage = e => received = e.data;
    await Promise.resolve();
    assert.equal(posted[0].action, 'open');
    assert.throws(() => socket.send('{}'));
    api.receive('stale-connection', 'open', '');
    assert.equal(opened, 0);
    api.receive('test-connection', 'open', '');
    api.receive('test-connection', 'open', '');
    assert.equal(opened, 1);
    const json = JSON.stringify({ jsonrpc: '2.0', method: 'textDocument/didChange', params: { text: 'sftp://must-not-be-rewritten/🐈' } });
    socket.send(json);
    assert.equal(posted.at(-1).data, json);
    api.receive('test-connection', 'message', json);
    assert.equal(received, json);
    socket.close();
    socket.close();
    api.receive('test-connection', 'close', '');
    assert.equal(closed, 1);
    assert.equal(socket.readyState, 3);
    assert.doesNotThrow(() => socket.send('{}'));
    let contentProvider;
    const contentModels = new Map();
    const models = { getModel: uri => contentModels.get(uri.toString()), createModel: (text, language, uri) => {
        const model = { text, uri }; contentModels.set(uri.toString(), model); return model;
    }};
    api.installNavigation({ registerCodeEditorOpenHandler: () => {} }, {},
        { registerTextModelContentProvider: (scheme, provider) => { assert.equal(scheme, 'sftp'); contentProvider = provider; } }, models);
    const header = URI.parse(root + '/unopened.h');
    const pendingRead = contentProvider.provideTextContent(header);
    const read = posted.at(-1);
    assert.equal(read.Event, 'Remote LSP Read');
    api.finishRead(read.request, 'int remote_add(int, int);');
    assert.equal((await pendingRead).text, 'int remote_add(int, int);');
    assert.equal(await contentProvider.provideTextContent(header), contentModels.get(header.toString()));
    let handler, selection;
    const editor = { setSelection: s => selection = s, revealPositionInCenter: () => {} };
    api.installNavigation({ registerCodeEditorOpenHandler: h => handler = h }, editor);
    assert.equal(await handler({ resource: URI.file('/local.c') }), null);
    const openedEditor = handler({ resource: URI.parse(root + '/target.h'), options: { selection: { startLineNumber: 7, startColumn: 3 } } });
    const request = posted.at(-1);
    assert.equal(request.Event, 'Remote LSP Open');
    api.finishNavigation(request.request, true);
    assert.equal(await openedEditor, editor);
    assert.equal(selection.startLineNumber, 7);
    assert.equal(selection.endColumn, 3);
    console.log('PASS: IPv6/ports/escaping, host isolation, typed URI mapping, SSH transport lifecycle, unsaved Unicode text, cross-file navigation');
})();
