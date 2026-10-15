const { chromium } = require('playwright');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = fs.mkdtempSync('/tmp/codeapp-remote-lsp-');
fs.writeFileSync(path.join(root, 'api.h'), 'int remote_add(int a, int b);\n');
fs.writeFileSync(path.join(root, 'api.c'), '#include "api.h"\nint remote_add(int a, int b) { return a + b; }\n');
fs.writeFileSync(path.join(root, 'main.c'), '#include "api.h"\nint main(void) { return remote_add(1, 2); }\n');
fs.writeFileSync(path.join(root, 'compile_commands.json'), JSON.stringify(['api.c', 'main.c'].map(file => ({ directory: root, file, arguments: ['/usr/bin/clang', '-Wall', '-Wextra', '-c', file] }))));
const server = spawn('python3', ['-m', 'http.server', '18761', '--bind', '127.0.0.1', '--directory', path.resolve('Resources/monaco-textmate.bundle')]);
const received = [], sent = [];
let starts = 0;
let clangd, browser, page, messageChain = Promise.resolve(), failures = [];
(async () => {
 try {
  browser = await chromium.launch({executablePath: process.env.CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true, args:['--no-sandbox']});
  page = await browser.newPage();
  page.on('pageerror', e => { if(!(e.message === 'object is not iterable (cannot read property Symbol(Symbol.iterator))' && e.stack.includes(':974:'))) failures.push(String(e.stack)); console.log('PAGE ERROR',String(e.stack)); });
  page.on('console', m => { if(m.type()==='error') console.log('BROWSER',m.text()); });
  await page.exposeFunction('__native', async m => {
   if (m.Event === 'Remote LSP Read') {
    const uri = new URL(m.uri), text = fs.readFileSync(decodeURIComponent(uri.pathname), 'utf8');
    await page.evaluate(({request,text}) => codeAppRemoteLSP.finishRead(request,text), {request:m.request,text});
   }
   if (m.Event === 'Remote LSP Open') {
    const uri = new URL(m.uri), text = fs.readFileSync(decodeURIComponent(uri.pathname), 'utf8');
    await page.evaluate(({uri,text,id}) => {const model=monaco.editor.getModel(monaco.Uri.parse(uri)) || monaco.editor.createModel(text,'c',monaco.Uri.parse(uri));editor.setModel(model);codeAppRemoteLSP.finishNavigation(id,true);}, {uri:m.uri,text,id:m.request});
   }
   if (m.Event !== 'Remote LSP') return;
   if (m.action === 'open') {
    starts++;
    clangd = spawn('/usr/bin/clangd', ['--background-index','--log=error'], {cwd:root});
    let buffer = Buffer.alloc(0);
    clangd.stderr.on('data',d=>console.log('CLANGD',String(d)));
    clangd.stdout.on('data',d=>{
     buffer=Buffer.concat([buffer,d]);
     while(true){
      const sep=buffer.indexOf('\r\n\r\n');if(sep<0)break;
      const len=Number(/Content-Length: (\d+)/i.exec(buffer.subarray(0,sep).toString())[1]);
      if(buffer.length<sep+4+len)break;
      const json=buffer.subarray(sep+4,sep+4+len).toString();buffer=buffer.subarray(sep+4+len);
      received.push(JSON.parse(json));
      messageChain=messageChain.then(()=>page.evaluate(({id,json})=>codeAppRemoteLSP.receive(id,'message',json),{id:m.id,json}));
     }
    });
    await page.evaluate(id=>codeAppRemoteLSP.receive(id,'open',''),m.id);
   } else if(m.action==='send'){
    sent.push(JSON.parse(m.data));clangd.stdin.write(`Content-Length: ${Buffer.byteLength(m.data)}\r\n\r\n${m.data}`);
   } else if(m.action==='close')clangd?.stdin.end();
  });
  await page.addInitScript(() => { window.webkit = {messageHandlers:{toggleMessageHandler:{postMessage:m=>window.__native(m)}}}; });
  await page.goto('http://127.0.0.1:18761');
  await page.waitForFunction(()=>typeof window.connectMonacoToLanguageServer==='function');
  const rootURI='sftp://test-host:22'+root;
  await page.evaluate(({rootURI,text})=>{
   const model=monaco.editor.createModel(text,'c',monaco.Uri.parse(rootURI+'/main.c')); editor.setModel(model);
   editor.updateOptions({suggest:{preview:true},inlineSuggest:{enabled:true}});
   connectMonacoToLanguageServer('codeapp-ssh:integration',[],btoa(rootURI),'','c',['c','cpp'],{});
  },{rootURI,text:fs.readFileSync(root+'/main.c','utf8')});
  await page.waitForFunction(()=>window.isLanguageServiceConnected());
  for(let i=0;i<100&&!sent.some(m=>m.method==='textDocument/didOpen');i++)await new Promise(r=>setTimeout(r,100));
  assert(sent.some(m=>m.method==='textDocument/didOpen'),'didOpen was sent');
  const init=sent.find(m=>m.method==='initialize');
  assert.equal(init.params.rootUri,'file://'+root);
  assert(!JSON.stringify(init).includes('wasm32-wasi'));
  await page.evaluate(()=>editor.getModel().setValue('#include "api.h"\nint main(void) { int unused_value; return remote_add(1, 2); }\n'));
  await page.waitForFunction(()=>monaco.editor.getModelMarkers({}).some(m=>m.severity===4 && m.message.includes('unused_value')),{},{timeout:20000});
  console.log('WARNING PASS');
  await page.evaluate(()=>editor.getModel().setValue('#include "api.h"\nint main(void) { return missing_symbol; }\n'));
  await page.waitForFunction(()=>monaco.editor.getModelMarkers({}).some(m=>m.message.includes('missing_symbol')),{},{timeout:20000});
  console.log('DIAGNOSTICS',await page.evaluate(()=>monaco.editor.getModelMarkers({}).map(m=>({uri:m.resource.toString(),message:m.message}))));
  await page.evaluate(()=>{editor.getModel().setValue('#include "api.h"\nint main(void) { return remote_ ; }\n'); editor.setPosition({lineNumber:2,column:editor.getModel().getLineContent(2).indexOf('remote_')+'remote_'.length+1});editor.focus();editor.trigger('test','editor.action.triggerSuggest',{});});
  await page.waitForFunction(()=>document.querySelector('.suggest-widget.visible')?.textContent.includes('remote_add'),{},{timeout:20000});
  await page.waitForFunction(()=>Array.from(document.querySelectorAll('[class*="ghost-text"]')).some(e=>e.textContent.includes('add')),{},{timeout:10000});
  console.log('COMPLETION AND INLINE PREVIEW PASS');
  await page.evaluate(()=>{editor.getModel().setValue('#include "api.h"\nint main(void) { return remote_add(1, 2); }\n'); editor.setPosition({lineNumber:2,column:27});});
  await new Promise(r=>setTimeout(r,600));
  await page.evaluate(()=>{editor.trigger('test','editor.action.showHover',{});});
  await page.waitForFunction(()=>document.querySelector('.monaco-hover')?.textContent.includes('remote_add'),{},{timeout:10000});
  console.log('HOVER PASS');
  await page.evaluate(()=>{editor.trigger('test','editor.action.revealDefinition',{});});
  await page.waitForFunction(()=>editor.getModel().uri.path.endsWith('/api.h')||editor.getModel().uri.path.endsWith('/api.c'),{},{timeout:20000});
  console.log('NAVIGATION',await page.evaluate(()=>({uri:editor.getModel().uri.toString(),position:editor.getPosition()})));
  assert.equal(starts,1,'source and header share one clangd');
  await page.evaluate(()=>editor.getModel().setValue('int broken = missing_cleanup_symbol;\n'));
  await page.waitForFunction(()=>monaco.editor.getModelMarkers({}).some(m=>m.message.includes('missing_cleanup_symbol')),{},{timeout:20000});
  await page.evaluate(()=>disconnectLanguageServer());
  await page.waitForFunction(()=>monaco.editor.getModelMarkers({}).length===0,{},{timeout:10000});
  console.log('DIAGNOSTIC CLEANUP PASS');
  await page.waitForFunction(()=>!isLanguageServiceConnected());
  assert.equal(failures.length,0,failures.join('\n'));
  console.log('PASS: real bundled Monaco client + native bridge contract + clangd initialization, unsaved diagnostics, completion, cross-file go-to-definition');
 } finally {
  fs.writeFileSync('/tmp/codeapp-lsp-browser-messages.json',JSON.stringify({root,sent,received,failures},null,2));
  if(page)await page.screenshot({path:'/tmp/codeapp-lsp-browser.png'}).catch(()=>{});
  clangd?.kill();await browser?.close();server.kill();
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
