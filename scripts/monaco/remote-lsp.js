/* SSH-backed transport for the existing Monaco language client. */
(() => {
    const sockets = new Map();
    const navigation = new Map();
    const reads = new Map();
    const post = (body) => window.webkit.messageHandlers.toggleMessageHandler.postMessage(body);

    class SSHLanguageSocket {
        constructor(url) {
            this.id = url.slice("codeapp-ssh:".length);
            this.readyState = 0;
            sockets.set(this.id, this);
            // The client installs its event handlers synchronously after construction.
            queueMicrotask(() => post({ Event: "Remote LSP", id: this.id, action: "open" }));
        }
        send(data) {
            if (this.readyState === 0) throw new Error("SSH language service is not open");
            if (this.readyState >= 2) return; // Match WebSocket.send during/after close.
            post({ Event: "Remote LSP", id: this.id, action: "send", data });
        }
        close() {
            if (this.readyState >= 2) return;
            this.readyState = 2;
            post({ Event: "Remote LSP", id: this.id, action: "close" });
            // Dispose listeners immediately; native cleanup may take longer on a dropped network.
            window.codeAppRemoteLSP.receive(this.id, "close", "");
        }
    }

    window.codeAppRemoteLSP = {
        createSocket(url) { return new SSHLanguageSocket(url); },
        receive(id, event, data) {
            const socket = sockets.get(id);
            if (!socket) return;
            if (event === "open" && socket.readyState === 0) {
                socket.readyState = 1;
                socket.onopen?.({});
            } else if (event === "message" && socket.readyState === 1) {
                socket.onmessage?.({ data });
            } else if (event === "close") {
                socket.readyState = 3;
                sockets.delete(id);
                socket.onclose?.({ code: data ? 1011 : 1000, reason: data });
            }
        },
        // Convert at the LSP client's typed URI boundary, never by replacing strings in JSON.
        // Source text, completion insertions and opaque server data must remain untouched.
        uriConverters(workspace, URI) {
            const root = URI.parse(workspace);
            if (root.scheme !== "sftp") return undefined;
            return {
                code2Protocol(uri) {
                    // vscode-languageclient reconstructs initialize.rootUri with Uri.file(fsPath).
                    // That synthetic file URI already names the remote root; other local URIs
                    // must never enter this session.
                    if (uri.scheme === "file" && uri.path === root.path) return uri.toString();
                    if (uri.scheme !== "sftp" || uri.authority !== root.authority) {
                        throw new Error(`A remote language service cannot access ${uri.toString()} (workspace ${root.toString()})`);
                    }
                    return uri.with({ scheme: "file", authority: "" }).toString();
                },
                protocol2Code(value) {
                    const uri = URI.parse(value);
                    return uri.scheme === "file"
                        ? uri.with({ scheme: "sftp", authority: root.authority }) : uri;
                }
            };
        },
        documentSelector(workspace, languages, URI) {
            const root = URI.parse(workspace);
            return root.scheme === "sftp"
                ? languages.map(language => ({ language, scheme: "sftp", pattern: undefined }))
                : languages;
        },
        installNavigation(service, editor, resolver, models) {
            // References and Peek Definition resolve models without opening an editor tab.
            resolver?.registerTextModelContentProvider("sftp", {
                async provideTextContent(uri) {
                    const existing = models.getModel(uri);
                    if (existing) return existing;
                    const request = crypto.randomUUID();
                    const content = new Promise(resolve => {
                        const timer = setTimeout(() => { reads.delete(request); resolve(null); }, 15000);
                        reads.set(request, text => { clearTimeout(timer); resolve(text); });
                    });
                    post({ Event: "Remote LSP Read", request, uri: uri.toString() });
                    const text = await content;
                    return text === null ? null : models.getModel(uri) ?? models.createModel(text, undefined, uri);
                }
            });
            service.registerCodeEditorOpenHandler(async (input) => {
                if (input.resource?.scheme !== "sftp") return null;
                const request = crypto.randomUUID();
                const opened = new Promise(resolve => {
                    const timer = setTimeout(() => {
                        navigation.delete(request);
                        resolve(false);
                    }, 15000);
                    navigation.set(request, success => { clearTimeout(timer); resolve(success); });
                });
                post({ Event: "Remote LSP Open", request, uri: input.resource.toString() });
                if (!await opened) return null;
                const selection = input.options?.selection;
                if (selection) {
                    editor.setSelection({
                        startLineNumber: selection.startLineNumber,
                        startColumn: selection.startColumn,
                        endLineNumber: selection.endLineNumber ?? selection.startLineNumber,
                        endColumn: selection.endColumn ?? selection.startColumn
                    });
                    editor.revealPositionInCenter({ lineNumber: selection.startLineNumber, column: selection.startColumn });
                }
                return editor;
            });
        },
        finishRead(request, text) {
            reads.get(request)?.(text);
            reads.delete(request);
        },
        finishNavigation(request, success) {
            navigation.get(request)?.(success);
            navigation.delete(request);
        }
    };
})();
