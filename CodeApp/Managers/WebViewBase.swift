//
//  WebViewBase.swift
//  Code
//
//  Created by Ken Chung on 16/11/2022.
//

import WebKit

private var ToolbarHandle: UInt8 = 0

class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        let fontExtension =
            url.absoluteString.components(separatedBy: ".").last?.lowercased() ?? "ttf"
        let mimeType = fontExtension == "otf" ? "font/otf" : "font/ttf"
        let response = URLResponse(
            url: url, mimeType: mimeType, expectedContentLength: -1, textEncodingName: nil)
        urlSchemeTask.didReceive(response)

        let fontName = url.absoluteString.components(separatedBy: "://").last?.components(
            separatedBy: "."
        ).first?.removingPercentEncoding

        if let fontName, let fontData = CodeFont.fontData(named: fontName) {
            urlSchemeTask.didReceive(fontData)
        }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {

    }
}

class WebViewBase: KBWebViewBase {
    var isMessageHandlerAdded = false
    // Only Monaco opts in, while its editor textarea has focus. Terminal and search
    // fields keep their own input handling.
    var repeatableEditorKeysEnabled = false
    private var schemeHandler = SchemeHandler()

    private lazy var repeatableEditorKeyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        for character in "abcdefghijklmnopqrstuvwxyz0123456789" {
            let input = String(character)
            let modifiers: [UIKeyModifierFlags] =
                character.isLetter
                ? [[], .shift, .alphaShift, [.shift, .alphaShift]] : [[], .alphaShift]
            for flags in modifiers {
                let command = UIKeyCommand(
                    input: input, modifierFlags: flags,
                    action: #selector(handleRepeatableEditorKey(_:)))
                // Let UIKit repeat these commands instead of starting press-and-hold
                // text alternatives, even after the web view has inserted text.
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticLocalization = false
                commands.append(command)
            }
        }
        return commands
    }()

    override var keyCommands: [UIKeyCommand]? {
        let inherited = super.keyCommands ?? []
        return acceptsRepeatableEditorKeys ? inherited + repeatableEditorKeyCommands : inherited
    }

    private var acceptsRepeatableEditorKeys: Bool {
        guard repeatableEditorKeysEnabled, let content = firstResponder(in: self)
        else { return false }
        // An explicit dead key or IME composition still belongs to the text input
        // system. Only ordinary key presses should bypass its accent picker.
        return (content as? UITextInput)?.markedTextRange == nil
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) { return responder }
        }
        return nil
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleRepeatableEditorKey(_:)) {
            return acceptsRepeatableEditorKeys
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func handleRepeatableEditorKey(_ command: UIKeyCommand) {
        guard acceptsRepeatableEditorKeys, let input = command.input else { return }
        let shifted = command.modifierFlags.contains(.shift)
        let uppercase = shifted != command.modifierFlags.contains(.alphaShift)
        let key = uppercase ? input.uppercased() : input
        callAsyncJavaScript(
            "return window.codeAppHardwareKeyboard?.typeKey(key, shiftKey);",
            arguments: ["key": key, "shiftKey": shifted], in: nil, in: .page,
            completionHandler: nil)
    }

    init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "shouldAllowUserInstalledFonts")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "fonts")
        super.init(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) {
            self.isInspectable = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var candidateView: UIView? {
        var candidateView: UIView? = nil
        for view in self.scrollView.subviews {
            let description = String(describing: type(of: view))
            if description.hasPrefix("WKContent")
                || description.hasSuffix("_CustomInputAccessoryView")
            {
                candidateView = view
            }
        }
        return candidateView
    }

    func removeInputAccessoryView() {
        objc_setAssociatedObject(
            self, &ToolbarHandle, nil, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func addInputAccessoryView(toolbar: UIView?) {
        guard let toolbar = toolbar else { return }
        guard let targetView = candidateView else { return }

        objc_setAssociatedObject(
            self, &ToolbarHandle, toolbar, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let newClass: AnyClass? = classWithCustomAccessoryView(targetView: targetView)
        object_setClass(targetView, newClass!)
    }

    func removeUIDropInteraction() {
        func findInteractionView(in subviews: [UIView]) -> UIView? {
            for subview in subviews {
                for interaction in subview.interactions {
                    if interaction is UIDragInteraction {
                        return subview
                    }
                }
                return findInteractionView(in: subview.subviews)
            }
            return nil
        }

        if let interactionView = findInteractionView(in: subviews) {
            interactionView.pasteConfiguration = nil
            for interaction in interactionView.interactions {
                if interaction is UIDragInteraction || interaction is UIDropInteraction {
                    interactionView.removeInteraction(interaction)
                }
            }
        }
    }

    private func classWithCustomAccessoryView(targetView: UIView) -> AnyClass? {
        guard let targetSuperClass = targetView.superclass else { return nil }
        let customInputAccessoryViewClassName = "\(targetSuperClass)_CustomInputAccessoryView"

        var newClass: AnyClass? = NSClassFromString(customInputAccessoryViewClassName)
        if newClass == nil {
            newClass = objc_allocateClassPair(
                object_getClass(targetView), customInputAccessoryViewClassName, 0)
        } else {
            return newClass
        }

        let newMethod = class_getInstanceMethod(
            WebViewBase.self, #selector(WebViewBase.getCustomInputAccessoryView))
        class_addMethod(
            newClass.self, #selector(getter: UIResponder.inputAccessoryView),
            method_getImplementation(newMethod!), method_getTypeEncoding(newMethod!))

        objc_registerClassPair(newClass!)

        return newClass
    }

    @objc func getCustomInputAccessoryView() -> UIView? {
        var superWebView: UIView? = self
        while (superWebView != nil) && !(superWebView is WKWebView) {
            superWebView = superWebView?.superview
        }
        let customInputAccessory = objc_getAssociatedObject(superWebView as Any, &ToolbarHandle)
        superWebView?.inputAssistantItem.leadingBarButtonGroups = []
        superWebView?.inputAssistantItem.trailingBarButtonGroups = []
        return customInputAccessory as? UIView
    }

    override open var inputAccessoryView: UIView? {
        // remove/replace the default accessory view
        return nil
    }
}
