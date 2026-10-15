/* Route repeating UIKit key commands through the editor in every Vim mode. */
(() => {
    const editors = new Set();
    let composing = false;

    function inputTarget() {
        const target = document.activeElement;
        return !composing && focusedEditor()?.hasTextFocus() && target instanceof HTMLTextAreaElement &&
            target.classList.contains("inputarea") ? target : null;
    }

    function focusedEditor() {
        return Array.from(editors).find(editor => editor.hasTextFocus() &&
            editor.getDomNode()?.contains(document.activeElement));
    }

    const reportFocus = () => window.webkit.messageHandlers.toggleMessageHandler.postMessage({
        Event: "Editor Keyboard Focus", focused: !!inputTarget()
    });
    document.addEventListener("focusin", reportFocus);
    document.addEventListener("focusout", () => queueMicrotask(reportFocus));
    document.addEventListener("compositionstart", () => { composing = true; reportFocus(); });
    document.addEventListener("compositionend", () => {
        composing = false;
        queueMicrotask(reportFocus);
    });

    window.codeAppHardwareKeyboard = {
        install(instance) {
            if (editors.has(instance)) return;
            editors.add(instance);
            instance.onDidDispose(() => {
                editors.delete(instance);
                reportFocus();
            });
            reportFocus();
        },
        typeKey(key, shiftKey = false) {
            const target = inputTarget();
            if (!target || !/^[a-z0-9]$/i.test(key)) return false;
            const editor = focusedEditor();
            const letter = /^[a-z]$/i.test(key);
            const options = {
                key, shiftKey, code: letter ? `Key${key.toUpperCase()}` : `Digit${key}`,
                keyCode: key.toUpperCase().charCodeAt(0),
                bubbles: true, cancelable: true
            };
            // UIKit consumes the physical event. Give Monaco (and monaco-vim) one
            // keydown; synthesize the text insertion only if no handler consumed it.
            // dispatchEvent itself has no browser text-insertion default action.
            const unhandled = target.dispatchEvent(new KeyboardEvent("keydown", options));
            if (unhandled && inputTarget() === target) {
                editor.trigger("keyboard", "type", { text: key });
            }
            target.dispatchEvent(new KeyboardEvent("keyup", options));
            return true;
        }
    };
})();
