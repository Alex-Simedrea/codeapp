import { MonacoLanguageClient } from "monaco-languageclient";
import {
  WebSocketMessageReader,
  WebSocketMessageWriter,
  toSocket,
} from "vscode-ws-jsonrpc";
import {
  CloseAction,
  ErrorAction,
  MessageTransports,
} from "vscode-languageclient";
import { CodeStorage } from "./storage";
import { Uri } from "vscode";
import { decodeBase64 } from "./utilities";

function languageServerConnectionDidDrop(languageIdentifier: string) {
  (window as any).webkit.messageHandlers.toggleMessageHandler.postMessage({
    Event: "Language Server Connection Dropped",
    languageIdentifier: languageIdentifier,
  });
}

export function isLanguageServiceConnected(): boolean {
  return CodeStorage.languageClientWebSocket?.readyState === WebSocket.OPEN;
}

export function disconnectLanguageServer() {
  CodeStorage.languageClientWebSocket?.close();
}

/** parameterized version , support all languageId */
export const connectMonacoToLanguageServer = (
  url: string,
  args: [string],
  base64PwdUrl: string,
  pwdBookmark: string,
  languageIdentifier: string,
  documentSelector?: any[],
  initializationOptions?: object
): WebSocket => {
  const remote = url.startsWith("codeapp-ssh:");
  const webSocket = remote ? (window as any).codeAppRemoteLSP.createSocket(url) : new WebSocket(url);
  CodeStorage.languageClientWebSocket = webSocket;

  webSocket.onopen = async () => {
    if (!remote) { webSocket.send(
      JSON.stringify({
        args: args,
        redirectStderr: false,
        workingDirectoryBookmark: pwdBookmark,
        isLanguageService: true,
      })
    );
    // quick hack: wait for the server to start (2 seconds)
    await new Promise((resolve) => setTimeout(resolve, 2000)); }
    if (webSocket.readyState !== 1) return;

    const socket = toSocket(webSocket);
    const reader = new WebSocketMessageReader(socket);
    const writer = new WebSocketMessageWriter(socket);
    const languageClient = createLanguageClient(
      {
        reader,
        writer,
      },
      languageIdentifier,
      decodeBase64(base64PwdUrl), documentSelector, initializationOptions
    );
    languageClient.start();
    reader.onClose(() => {
      if (!remote) languageServerConnectionDidDrop(languageIdentifier);
      languageClient.stop();
    });
  };
  return webSocket;
};

const createLanguageClient = (
  transports: MessageTransports,
  languageIdentifier: string,
  workspaceUri: string,
  documentSelector?: any[],
  initializationOptions?: object
): MonacoLanguageClient => {
  return new MonacoLanguageClient({
    name: "Sample Language Client",
    clientOptions: {
      // use a language id as a document selector
      documentSelector: (window as any).codeAppRemoteLSP.documentSelector(workspaceUri, documentSelector ?? [languageIdentifier], Uri),
      uriConverters: (window as any).codeAppRemoteLSP.uriConverters(workspaceUri, Uri),
      initializationOptions: initializationOptions ?? {},
      // disable the default error handler
      errorHandler: {
        error: () => ({ action: ErrorAction.Continue }),
        closed: () => ({ action: CloseAction.DoNotRestart }),
      },
      workspaceFolder: {
        index: 0,
        name: "workspace",
        uri: Uri.parse(workspaceUri),
      },
    },
    // create a language client connection from the JSON RPC connection on demand
    connectionProvider: {
      get: () => {
        return Promise.resolve(transports);
      },
    },
  });
};
