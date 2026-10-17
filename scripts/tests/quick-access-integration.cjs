const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const path = require("node:path");
const { chromium } = require("playwright");
const server = spawn("python3", [
  "-m",
  "http.server",
  "18763",
  "--bind",
  "127.0.0.1",
  "--directory",
  path.resolve("Resources/monaco-textmate.bundle"),
]);
let browser;
(async () => {
  try {
    browser = await chromium.launch({
      executablePath:
        process.env.CHROME_EXECUTABLE ||
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      headless: true,
    });
    const page = await browser.newPage();
    page.setDefaultTimeout(10000);
    await page.route("**/favicon.ico", (route) =>
      route.fulfill({ status: 204 }),
    );
    const errors = [];
    page.on("pageerror", (e) => {
      if (!e.message.includes("object is not iterable")) errors.push(e.stack);
    });
    page.on("console", (m) => {
      if (m.type() === "error") {
        console.log("BROWSER:", m.text());
        errors.push(m.text());
      }
    });
    let state,
      files,
      opened = [],
      calls = [];
    await page.exposeFunction("__native", async (m) => {
      if (m.Event !== "Workspace") return;
      calls.push(m);
      if (m.action === "cancel") return;
      let result, error;
      try {
        if (m.action !== "snapshot" && m.generation !== state.generation)
          throw Error("Workspace changed");
        if (m.action === "snapshot") result = state;
        else if (m.action === "home") result = { uri: state.workspace };
        else if (m.action === "files") result = { files: Object.keys(files) };
        else if (m.action === "stat") {
          if (!(m.uri in files)) throw Error("File not found");
          result = { type: "file", size: files[m.uri].length, mtime: 0 };
        } else if (m.action === "read") result = { text: files[m.uri] };
        else if (m.action === "forget") {
          state.history = state.history.filter((u) => u !== m.uri);
          result = {};
        } else if (m.action === "open") {
          if (!(m.uri in files)) throw Error("File not found");
          opened.push(m.uri);
          state.active = m.uri;
          state.history = [m.uri, ...state.history.filter((u) => u !== m.uri)];
          if (!state.editors.some((e) => e.uri === m.uri))
            state.editors.push({ uri: m.uri, dirty: false });
          await page.evaluate(
            ({ uri, text }) => {
              const model = monaco.editor.getModel(monaco.Uri.parse(uri));
              onRequestNewTextModel(
                btoa(uri),
                btoa(unescape(encodeURIComponent(model?.getValue() ?? text))),
              );
            },
            { uri: m.uri, text: files[m.uri] },
          );
          result = { state };
        } else throw Error("Unknown action: " + m.action);
      } catch (e) {
        error = e.message;
      }
      await page.evaluate(
        ({ id, result, error }) => codeAppWorkspace.receive(id, result, error),
        { id: m.id, result, error },
      );
    });
    await page.addInitScript(() => {
      window.webkit = {
        messageHandlers: {
          toggleMessageHandler: { postMessage: (m) => window.__native(m) },
        },
      };
    });
    await page.goto("http://127.0.0.1:18763");
    await page.waitForFunction(() => window.codeAppWorkspace && window.editor);
    for (const root of [
      "file:///tmp/workspace",
      "sftp://dev@host:22/project%20one",
    ]) {
      const a = root + "/main.c",
        b = root + "/src/another.c",
        closed = root + "/recent.txt";
      files = {
        [a]: "int main() { return 0; }\n",
        [b]: Array.from({ length: 50 }, (_, i) => "line " + i).join("\n"),
        [closed]: "recent content",
      };
      state = {
        workspace: root,
        generation: root + "-generation",
        active: a,
        editors: [{ uri: a, dirty: true }],
        history: [a, closed],
      };
      await page.evaluate(
        ({ uri }) => {
          onRequestNewTextModel(btoa(uri), btoa("unsaved edits"));
          editor.focus();
        },
        { uri: a },
      );
      await page.keyboard.press("Meta+p");
      await page.waitForSelector(
        ".quick-input-widget .quick-input-list .monaco-list-row",
      );
      await page.waitForFunction(() =>
        document
          .querySelector(".quick-input-widget")
          ?.textContent.includes("recent.txt"),
      );
      await page.keyboard.type("anoc");
      await page.waitForFunction(() =>
        document
          .querySelector(".quick-input-widget")
          ?.textContent.includes("another.c"),
      );
      if (root.startsWith("file:"))
        await page.screenshot({ path: "/tmp/codeapp-quick-access.png" });
      await page.keyboard.press("Enter");
      await page.waitForFunction(
        (uri) => editor.getModel()?.uri.toString() === uri,
        b,
      );
      assert.equal(opened.at(-1), b);
      // Existing dirty buffer must be activated without a disk reload.
      await page.keyboard.press("Meta+p");
      await page.keyboard.type("main.c");
      await page.waitForFunction(() =>
        document
          .querySelector(".quick-input-widget")
          ?.textContent.includes("main.c"),
      );
      await page.keyboard.press("Enter");
      await page.waitForFunction(
        (uri) => editor.getModel()?.uri.toString() === uri,
        a,
      );
      assert.equal(
        await page.evaluate(() => editor.getValue()),
        "unsaved edits",
      );
      // Stock Go to File parses :line:column suffixes.
      await page.keyboard.press("Meta+p");
      await page.keyboard.type("another.c:12:3");
      await page.waitForFunction(() =>
        document
          .querySelector(".quick-input-widget")
          ?.textContent.includes("another.c"),
      );
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => editor.getPosition().lineNumber === 12);
      assert.equal(await page.evaluate(() => editor.getPosition().column), 3);
      // Absolute paths are resolved through the native filesystem service.
      await page.keyboard.press("Meta+p");
      await page.keyboard.type(decodeURIComponent(new URL(a).pathname));
      await page.waitForFunction(() =>
        document
          .querySelector(".quick-input-widget .monaco-list-row.focused")
          ?.textContent.includes("main.c"),
      );
      await page.keyboard.press("Enter");
      await page.waitForFunction(
        (uri) => editor.getModel()?.uri.toString() === uri,
        a,
      );
      // Canceling a search must not activate a preview tab.
      const previous = opened.length;
      await page.keyboard.press("Meta+p");
      await page.keyboard.type("missing");
      await page.keyboard.press("Escape");
      assert.equal(opened.length, previous);
      // Existing command, symbol and line providers stay on the same palette.
      await page.evaluate(() =>
        editor.trigger("test", "editor.action.quickCommand", {}),
      );
      await page.waitForFunction(() =>
        document
          .querySelector(".quick-input-widget .monaco-inputbox input")
          ?.value.startsWith(">"),
      );
      await page.keyboard.press("Escape");
      // Rapid close/reopen must not dispose the stock provider's pending searches.
      for (let repeat = 0; repeat < 8; repeat++) {
        await page.keyboard.press("Meta+p");
        await page.keyboard.type("an");
        await page.keyboard.press("Escape");
      }
    }
    assert(calls.some((c) => c.action === "files"));
    assert.equal(errors.length, 0, errors.join("\n"));
    console.log(
      "PASS: stock VS Code Go to File, local/SFTP files, recents, dirty buffers, fuzzy matching, line suffixes, cancellation, existing command palette",
    );
  } finally {
    await browser?.close();
    server.kill();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
