const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const { chromium } = require('playwright');

// Exercise the same entry point as UIKit, against the real downloaded Monaco/Vim.
const server = spawn('python3', ['-m', 'http.server', '18762', '--bind', '127.0.0.1',
    '--directory', path.resolve('Resources/monaco-textmate.bundle')]);
let browser;
(async () => {
    try {
        browser = await chromium.launch({
            executablePath: process.env.CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            headless: true
        });
        const page = await browser.newPage({
            userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 (KHTML, like Gecko) CodeApp'
        });
        await page.addInitScript(() => {
            window.nativeEvents = [];
            window.webkit = { messageHandlers: { toggleMessageHandler: {
                postMessage: message => nativeEvents.push(message)
            } } };
        });
        await page.goto('http://127.0.0.1:18762');
        await page.waitForFunction(() => window.editor && window.codeAppHardwareKeyboard);
        const text = Array.from({ length: 20 }, () => 'abcdefghijklmnopqrstuvwxyz').join('\n');
        await page.evaluate(text => {
            editor.setModel(monaco.editor.createModel(text, 'plaintext'));
            toggleVimMode(true);
            editor.setPosition({ lineNumber: 10, column: 10 });
            editor.focus();
        }, text);
        const keys = value => page.evaluate(value => {
            for (const key of value) {
                if (!codeAppHardwareKeyboard.typeKey(key, /^[A-Z]$/.test(key))) throw new Error('key dropped: ' + key);
            }
        }, value);
        const position = () => page.evaluate(() => editor.getPosition());
        const value = () => page.evaluate(() => editor.getValue());
        const mode = () => page.evaluate(() => nativeEvents.filter(e => e.Event === 'vim.mode.change').at(-1).newMode);
        const focus = () => page.evaluate(() => nativeEvents.filter(e => e.Event === 'Editor Keyboard Focus').at(-1).focused);
        assert.equal(await focus(), true);

        // Native repeats are separate invocations, with no browser insertion event.
        await keys('hhh'); assert.deepEqual(await position(), { lineNumber: 10, column: 7 });
        await keys('jjj'); assert.deepEqual(await position(), { lineNumber: 13, column: 7 });
        await keys('kkk'); assert.deepEqual(await position(), { lineNumber: 10, column: 7 });
        await keys('lll'); assert.deepEqual(await position(), { lineNumber: 10, column: 10 });
        assert.equal(await value(), text, 'normal navigation must not insert text');

        await keys('itesta');
        assert.equal(await mode(), '--INSERT--');
        assert.equal((await value()).split('\n')[9], 'abcdefghitesta' + 'jklmnopqrstuvwxyz');
        await keys('aaa111AAA');
        assert.equal((await value()).split('\n')[9], 'abcdefghitesta' + 'aaa111AAAjklmnopqrstuvwxyz');
        await page.keyboard.press('Escape');
        const afterInsert = await value();
        const start = await position();
        await keys('hhhlllkkkjjj');
        assert.deepEqual(await position(), start);
        assert.equal(await value(), afterInsert);

        // Visual character, line and block selections must still consume commands.
        await keys('vlll');
        assert.equal(await mode(), '--VISUAL--');
        assert.equal(await page.evaluate(() => editor.getSelection().isEmpty()), false);
        assert.equal(await value(), afterInsert);
        await page.keyboard.press('Escape');
        await keys('Vjj');
        assert.equal(await mode(), '--VISUAL LINE--');
        assert.equal(await value(), afterInsert);
        await page.keyboard.press('Escape');
        await page.keyboard.press('Control+v');
        await keys('lljj');
        assert.equal(await mode(), '--VISUAL BLOCK--');
        assert.equal(await value(), afterInsert);
        await page.keyboard.press('Escape');

        // Single-character replacement and continuous replace mode.
        await page.evaluate(() => editor.setPosition({ lineNumber: 1, column: 1 }));
        await keys('rZ');
        assert.equal((await value()).split('\n')[0], 'Zbcdefghijklmnopqrstuvwxyz');
        await keys('Rxxx');
        assert.equal(await mode(), '--REPLACE--');
        assert.equal((await value()).split('\n')[0], 'xxxdefghijklmnopqrstuvwxyz');
        await page.keyboard.press('Escape');

        // Counts/operator-pending state also use the original Vim handler.
        await keys('2dd');
        assert.equal((await value()).split('\n').length, 18);
        await keys('u');
        assert.equal((await value()).split('\n').length, 20);

        // Plain Monaco also repeats. Preserve type's undo grouping and read-only checks.
        await page.evaluate(() => { toggleVimMode(false); editor.setValue(''); editor.focus(); });
        await keys('aaaAAA111');
        assert.equal(await value(), 'aaaAAA111');
        await page.evaluate(() => editor.trigger('test', 'undo', {}));
        assert.equal(await value(), '');
        await page.evaluate(() => editor.updateOptions({ readOnly: true }));
        await keys('aaa');
        assert.equal(await value(), '');
        await page.evaluate(() => editor.updateOptions({ readOnly: false }));

        // Find inputs and other native fields must not be routed into the editor.
        await page.evaluate(() => editor.trigger('test', 'actions.find', {}));
        await page.getByRole('textbox', { name: 'Find', exact: true }).focus();
        assert.equal(await focus(), false);
        assert.equal(await page.evaluate(() => codeAppHardwareKeyboard.typeKey('a')), false);
        await page.keyboard.type('find');
        assert.equal(await value(), '');
        await page.keyboard.press('Escape');
        await page.evaluate(() => editor.focus());
        assert.equal(await focus(), true);
        await keys('bbb');
        assert.equal(await value(), 'bbb');
        assert.equal(await page.evaluate(() => codeAppHardwareKeyboard.typeKey("'")), false);
        // Explicit IME/dead-key composition keeps native text handling.
        await page.evaluate(() => document.activeElement.dispatchEvent(
            new CompositionEvent('compositionstart', { bubbles: true, data: '' })));
        assert.equal(await focus(), false);
        assert.equal(await page.evaluate(() => codeAppHardwareKeyboard.typeKey('a')), false);
        await page.evaluate(() => document.activeElement.dispatchEvent(
            new CompositionEvent('compositionend', { bubbles: true, data: '' })));
        assert.equal(await focus(), true);
        // Production setup also registers both diff panes and recreated editors.
        await page.evaluate(() => switchToDiffView(
            btoa('original'), btoa('modified'),
            btoa('file:///repeat-original.txt'), btoa('file:///repeat-modified.txt')));
        await page.locator('.monaco-diff-editor .editor.modified textarea.inputarea').focus();
        await keys('zzz');
        assert.equal(await page.evaluate(() => monaco.editor.getModel(
            monaco.Uri.parse('file:///repeat-modified.txt')).getValue()), 'zzzmodified');
        assert.equal(await page.evaluate(() => monaco.editor.getModel(
            monaco.Uri.parse('file:///repeat-original.txt')).getValue()), 'original');
        await page.evaluate(() => {
            switchToNormalView();
            onRequestNewTextModel(btoa('file:///repeat-recreated.txt'), btoa(''));
        });
        await page.locator('textarea.inputarea').focus();
        await keys('yyy');
        assert.equal(await page.evaluate(() => monaco.editor.getModel(
            monaco.Uri.parse('file:///repeat-recreated.txt')).getValue()), 'yyy');
        console.log('PASS: native key routing, insert/normal/visual/line/block/replace modes, counts, undo, plain Monaco, read-only, focus isolation, composition, diff/recreated editors');
    } finally {
        await browser?.close();
        server.kill();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
