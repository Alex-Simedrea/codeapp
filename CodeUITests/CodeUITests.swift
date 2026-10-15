//
//  CodeUITests.swift
//  CodeUITests
//
//  Created by Ken Chung on 1/2/2023.
//

import CoreText
import SwiftUI
import XCTest

@testable import CodeUI

final class CodeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Clean all UserDefaults
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }

    @MainActor
    func testMonacoHardwareKeyRepeatRoutesTypingAndVimCommands() async throws {
        var options = EditorOptions()
        options.vimEnabled = true
        let implementation = MonacoImplementation(
            options: options, theme: EditorTheme(dark: nil, light: nil))
        let webView = try XCTUnwrap(implementation.view as? WebViewBase)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        webView.frame = window.bounds
        window.rootViewController!.view.addSubview(webView)
        window.makeKeyAndVisible()
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: "toggleMessageHandler")
            window.isHidden = true
        }
        func waitFor(_ script: String) async throws {
            for _ in 0..<200 {
                if (try? await webView.evaluateJavaScriptAsync(script)) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("Monaco did not reach expected state: \(script)")
            throw NSError(domain: "MonacoTestTimeout", code: 1)
        }
        try await waitFor("typeof window.toggleVimMode === 'function'")
        try await webView.evaluateJavaScriptAsync(
            """
            editor.setModel(monaco.editor.createModel('abcdef\\nabcdef\\nabcdef\\nabcdef', 'plaintext'));
            toggleVimMode(true);
            editor.setPosition({lineNumber: 3, column: 4});
            editor.focus();
            """)
        try await waitFor("editor.hasTextFocus()")
        for _ in 0..<100 {
            if webView.repeatableEditorKeysEnabled { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(webView.repeatableEditorKeysEnabled)
        let action = #selector(WebViewBase.handleRepeatableEditorKey(_:))
        for _ in 0..<100 {
            if webView.canPerformAction(action, withSender: nil) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            webView.canPerformAction(action, withSender: nil),
            "Native editor input did not acquire focus: \(webView.scrollView.subviews)")
        func send(_ input: String, flags: UIKeyModifierFlags = []) throws {
            let command = try XCTUnwrap(
                webView.keyCommands?.first {
                    $0.action == action && $0.input == input && $0.modifierFlags == flags
                })
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            webView.handleRepeatableEditorKey(command)
        }
        // UIKit's repeating action must work both before and after inserting text.
        for key in "itesta" { try send(String(key)) }
        try await waitFor("editor.getModel().getLineContent(3) === 'abctestadef'")
        try send("a", flags: .shift)
        try send("b", flags: .alphaShift)
        try send("c", flags: [.shift, .alphaShift])
        try await waitFor("editor.getModel().getLineContent(3) === 'abctestaABcdef'")
        try await webView.evaluateJavaScriptAsync(
            "document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true}))"
        )
        for _ in 0..<2 { try send("k") }
        try await waitFor("editor.getPosition().lineNumber === 1")
        try await waitFor("editor.getModel().getLineContent(3) === 'abctestaABcdef'")

        // Override stays out of find fields and unrelated web views (e.g. terminal).
        try await webView.evaluateJavaScriptAsync("editor.trigger('test', 'actions.find', {})")
        for _ in 0..<100 {
            if !webView.repeatableEditorKeysEnabled { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(webView.repeatableEditorKeysEnabled)
        XCTAssertFalse(webView.canPerformAction(action, withSender: nil))
        XCTAssertFalse(WebViewBase().keyCommands?.contains { $0.action == action } ?? false)
    }

    //  https://github.com/thebaselab/codeapp/issues/746
    @MainActor
    func testAppendAndFocusNewEditor() throws {
        let app = MainApp()

        let editorOne = EditorInstance(view: AnyView(EmptyView()), title: "editorOne")
        let editorTwo = EditorInstance(view: AnyView(EmptyView()), title: "editorTwo")

        app.appendAndFocusNewEditor(editor: editorOne)
        app.appendAndFocusNewEditor(editor: editorTwo)

        XCTAssertEqual(app.editors.count, 1)
    }

    @MainActor
    func testAppendAndFocusNewEditor_alwaysInNewTab() throws {
        let app = MainApp()

        let editorOne = EditorInstance(view: AnyView(EmptyView()), title: "editorOne")
        let editorTwo = EditorInstance(view: AnyView(EmptyView()), title: "editorTwo")

        app.appendAndFocusNewEditor(editor: editorOne)
        app.appendAndFocusNewEditor(editor: editorTwo, alwaysInNewTab: true)

        XCTAssertEqual(app.editors.count, 2)
    }

    @MainActor
    func testAppendAndFocusNewEditor_alwaysInNewTabWithUserOption() throws {
        UserDefaults.standard.set(true, forKey: "alwaysOpenInNewTab")

        let app = MainApp()

        let editorOne = EditorInstance(view: AnyView(EmptyView()), title: "editorOne")
        let editorTwo = EditorInstance(view: AnyView(EmptyView()), title: "editorTwo")

        app.appendAndFocusNewEditor(editor: editorOne)
        app.appendAndFocusNewEditor(editor: editorTwo)

        XCTAssertEqual(app.editors.count, 2)

        UserDefaults.standard.removeObject(forKey: "alwaysOpenInNewTab")
    }

    @MainActor
    func testBackgroundTerminalCreationDoesNotStealFocus() async throws {
        let manager = TerminalManager(rootURL: getRootDirectory(), options: TerminalOptions())
        let terminal = manager.createTerminal()
        // Regression: creation used to call focus unconditionally after half a second.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(manager.isFocused)
        XCTAssertFalse(terminal.isFocusRequested)
        manager.closeTerminal(id: terminal.id)
    }

    @MainActor
    func testTerminalFocusMovesBetweenTabsAndCanBeReleased() {
        let manager = TerminalManager(rootURL: getRootDirectory(), options: TerminalOptions())
        let first = manager.activeTerminal!
        manager.setFocused(true)
        XCTAssertTrue(first.isFocusRequested)
        let second = manager.createTerminal()
        XCTAssertFalse(first.isFocusRequested)
        XCTAssertTrue(second.isFocusRequested)
        manager.setFocused(false)
        XCTAssertFalse(first.isFocusRequested)
        XCTAssertFalse(second.isFocusRequested)
        manager.setActiveTerminal(id: first.id)
        XCTAssertFalse(first.isFocusRequested)
        manager.closeTerminal(id: second.id)
    }

    @MainActor
    func testTerminalBlurReleasesDOMFocusWithoutFocusingOverlay() async throws {
        let terminal = TerminalInstance(root: getRootDirectory(), options: TerminalOptions())
        defer { terminal.cleanup() }
        for _ in 0..<100 {
            if terminal.isReady { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(terminal.isReady)
        let focused =
            try await terminal.webView.evaluateJavaScriptAsync(
                "term.textarea.focus(); document.activeElement === term.textarea") as? Bool
        XCTAssertEqual(focused, true)
        terminal.blur()
        let released =
            try await terminal.webView.evaluateJavaScriptAsync(
                "document.activeElement !== term.textarea && document.activeElement.id !== 'overlay'"
            ) as? Bool
        XCTAssertEqual(released, true)
    }

    @MainActor
    private func visibleTerminal(options: TerminalOptions) -> (TerminalInstance, UIWindow) {
        let terminal = TerminalInstance(root: getRootDirectory(), options: options)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 300)
        terminal.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 300)
        window.rootViewController!.view.addSubview(terminal.webView)
        window.isHidden = false
        return (terminal, window)
    }

    @MainActor
    private func waitForJavaScript(_ script: String, in terminal: TerminalInstance) async throws {
        for _ in 0..<200 {
            if (try? await terminal.webView.evaluateJavaScriptAsync(script)) as? Bool == true {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Terminal did not reach expected state: \(script)")
        throw NSError(domain: "TerminalTestTimeout", code: 1)
    }

    @MainActor
    func testColdTerminalLoadsFontBeforeMeasuringAndReportsFittedSize() async throws {
        var options = TerminalOptions()
        options.fontFamily = CodeFont.jetBrainsMonoFamilyName
        options.fontSize = 28
        let (terminal, window) = visibleTerminal(options: options)
        let provider = TerminalSizeRecorder()
        terminal.terminalServiceProvider = provider
        defer {
            terminal.cleanup()
            window.isHidden = true
        }
        try await waitForJavaScript(
            "terminalFontsReady && getTerminalSize() !== null", in: terminal)
        try await waitForJavaScript("terminalReadyReported", in: terminal)
        XCTAssertTrue(terminal.isReady)
        let validMetrics =
            try await terminal.webView.evaluateJavaScriptAsync(
                """
                (() => {
                  const font = \(String(reflecting: CodeFont.jetBrainsMonoFamilyName));
                  const loaded = Array.from(document.fonts).some(f => f.family === font && f.status === 'loaded');
                  const canvas = document.createElement('canvas');
                  const ctx = canvas.getContext('2d');
                  ctx.font = '28px ' + JSON.stringify(font);
                  const naturalWidth = ctx.measureText('W'.repeat(100)).width / 100;
                  const cellWidth = term.element.querySelector('.xterm-screen').getBoundingClientRect().width / term.cols;
                  return loaded && localEcho._disposables.length === 0 && term.options.fontFamily === font &&
                    Math.abs(cellWidth - naturalWidth) < 1 && term.cols === fitAddon.proposeDimensions().cols;
                })()
                """) as? Bool
        XCTAssertEqual(validMetrics, true)
        // The bridge delivers events asynchronously after the JavaScript call completes.
        for _ in 0..<100 {
            if provider.sizes.last?.cols == (await terminal.getTerminalSize())?.cols { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let measuredSize = await terminal.getTerminalSize()
        let size = try XCTUnwrap(measuredSize)
        XCTAssertEqual(provider.sizes.last?.cols, size.cols)
        XCTAssertEqual(provider.sizes.last?.rows, size.rows)
    }

    @MainActor
    func testFontLoadAndPaneResizeRefreshRemoteTerminalDimensions() async throws {
        var options = TerminalOptions()
        options.fontFamily = CodeFont.jetBrainsMonoFamilyName
        let (terminal, window) = visibleTerminal(options: options)
        let provider = TerminalSizeRecorder()
        terminal.terminalServiceProvider = provider
        defer {
            terminal.cleanup()
            window.isHidden = true
        }
        try await waitForJavaScript(
            "terminalFontsReady && getTerminalSize() !== null", in: terminal)
        let measuredOriginalSize = await terminal.getTerminalSize()
        let originalSize = try XCTUnwrap(measuredOriginalSize)
        // Hold font readiness to reproduce a slow cold WebKit font load deterministically.
        _ = try await terminal.webView.evaluateJavaScriptAsync(
            """
            window.originalFontLoad = document.fonts.load.bind(document.fonts);
            document.fonts.load = (...args) => new Promise(resolve => {
              window.releaseFontLoad = () => resolve(window.originalFontLoad(...args));
            });
            void 0;
            """)
        terminal.setFontSize(size: 28)
        try await waitForJavaScript("typeof window.releaseFontLoad === 'function'", in: terminal)
        let reportCount = provider.sizes.count
        terminal.fitToContainer()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(provider.sizes.count, reportCount)
        let pendingSize = await terminal.getTerminalSize()
        XCTAssertNil(pendingSize)
        _ = try await terminal.webView.evaluateJavaScriptAsync(
            "window.releaseFontLoad(); document.fonts.load = window.originalFontLoad; void 0")
        try await waitForJavaScript(
            "terminalFontsReady && term.options.fontSize === 28", in: terminal)
        let measuredNewSize = await terminal.getTerminalSize()
        let newSize = try XCTUnwrap(measuredNewSize)
        XCTAssertLessThan(newSize.cols, originalSize.cols)
        terminal.webView.frame.size.width = 400
        try await waitForJavaScript("term.cols < \(newSize.cols)", in: terminal)
        terminal.webView.frame.size.width = 800
        try await waitForJavaScript("term.cols === \(newSize.cols)", in: terminal)
        for _ in 0..<100 {
            if provider.sizes.last?.cols == newSize.cols { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(provider.sizes.last?.cols, newSize.cols)
        XCTAssertEqual(provider.sizes.last?.rows, newSize.rows)
    }

    @MainActor
    func testEditorFocusCancelsPendingTerminalFocus() async throws {
        let app = MainApp()
        app.focusPane(.terminal)
        app.focusPane(.editor, activate: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(app.focusedPane, .editor)
        XCTAssertFalse(app.terminalManager.isFocused)
        XCTAssertFalse(app.terminalManager.activeTerminal!.isFocusRequested)
    }

    @MainActor
    func testHiddenFilesAreFilteredAtEveryDepthAndCanBeShownAgain() {
        typealias Item = WorkSpaceStorage.FileItemRepresentable
        let hidden = Item(url: "file:///project/outer/inner/.secret", isDirectory: false)
        let visible = Item(url: "file:///project/outer/inner/file.swift", isDirectory: false)
        var inner = Item(url: "file:///project/outer/inner", isDirectory: true)
        inner.subFolderItems = [hidden, visible]
        var outer = Item(url: "file:///project/outer", isDirectory: true)
        outer.subFolderItems = [inner]
        let tree = ExplorerFileTree(
            searchString: "", onDrag: { _ in NSItemProvider() },
            onMoveFile: { _, _ in })
        let filtered = tree.foldersWithFilter(folder: [outer])
        XCTAssertEqual(filtered[0].subFolderItems?[0].subFolderItems, [visible])
        tree.showHiddenFiles = true
        let unfiltered = tree.foldersWithFilter(folder: [outer])
        XCTAssertEqual(unfiltered[0].subFolderItems?[0].subFolderItems, [hidden, visible])
        // Filtering must not remove hidden entries from the workspace's source data.
        XCTAssertEqual(outer.subFolderItems?[0].subFolderItems, [hidden, visible])
    }

    @MainActor
    func testBundledJetBrainsMonoNerdFontIncludesPowerlineGlyph() throws {
        let font = try XCTUnwrap(CodeFont.font(named: CodeFont.jetBrainsMonoFamilyName, size: 14))
        XCTAssertEqual(font.familyName, CodeFont.jetBrainsMonoFamilyName)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let ctFont = CTFontCreateWithName(font.fontName as CFString, 14, nil)
        var character: UniChar = 0xE0B0
        var glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1))
        XCTAssertNotEqual(glyph, 0)
        XCTAssertNotNil(CodeFont.fontData(named: CodeFont.jetBrainsMonoFamilyName))
    }

    func testParseRemoteURL_userExtension() throws {
        let url = URL(string: "git@github.com:thebaselab/codeapp.git")!
        let parsed = LocalGitCredentialsHelper.parseRemoteURL(url: url)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.host, "github.com")
        XCTAssertEqual(parsed!.scheme, "ssh")
        XCTAssertEqual(parsed!.path, "/thebaselab/codeapp.git")
    }

    func testParseRemoteURL_noUserExtension() throws {
        let url = URL(string: "git@github.com:/codeapp.git")!
        let parsed = LocalGitCredentialsHelper.parseRemoteURL(url: url)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.host, "github.com")
        XCTAssertEqual(parsed!.scheme, "ssh")
        XCTAssertEqual(parsed!.path, "/codeapp.git")
    }
}

private final class TerminalSizeRecorder: TerminalServiceProvider {
    var sizes: [(cols: Int, rows: Int)] = []
    func setWindowsSize(cols: Int, rows: Int) { sizes.append((cols, rows)) }
    func kill() {}
    func write(data: Data) {}
    func onStdout(callback: @escaping (Data) -> Void) {}
    func onStderr(callback: @escaping (Data) -> Void) {}
    func onDisconnect(callback: @escaping () -> Void) {}
}
