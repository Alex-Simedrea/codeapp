/* Native service adapters for VS Code's unmodified Go to File provider. */
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { AnythingQuickAccessProvider } from "vscode/vscode/vs/workbench/contrib/search/browser/anythingQuickAccess";
import { Registry } from "vscode/vscode/vs/platform/registry/common/platform";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { Extensions } from "vscode/vscode/vs/platform/quickinput/common/quickAccess";
import { StandaloneServices } from "vscode/vscode/vs/editor/standalone/browser/standaloneServices";
import { IInstantiationService } from "vscode/vscode/vs/platform/instantiation/common/instantiation";
import { ServiceCollection } from "vscode/vscode/vs/platform/instantiation/common/serviceCollection";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { ISearchService } from "vscode/vscode/vs/workbench/services/search/common/search.service";
import { IWorkspaceContextService } from "vscode/vscode/vs/platform/workspace/common/workspace.service";
import { IEditorService } from "vscode/vscode/vs/workbench/services/editor/common/editorService.service";
import { IEditorGroupsService } from "vscode/vscode/vs/workbench/services/editor/common/editorGroupsService.service";
import { IHistoryService } from "vscode/vscode/vs/workbench/services/history/common/history.service";
import { IFileService } from "vscode/vscode/vs/platform/files/common/files.service";
import { IPathService } from "vscode/vscode/vs/workbench/services/path/common/pathService.service";
import { ILabelService } from "vscode/vscode/vs/platform/label/common/label.service";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { IWorkingCopyService } from "vscode/vscode/vs/workbench/services/workingCopy/common/workingCopyService.service";
import { IConfigurationService } from "vscode/vscode/vs/platform/configuration/common/configuration.service";
import { IQuickInputService } from "vscode/vscode/vs/platform/quickinput/common/quickInput.service";
import { URI } from "vscode/vscode/vs/base/common/uri";
import { DisposableStore } from "vscode/vscode/vs/base/common/lifecycle";
import { CancellationToken } from "vscode/vscode/vs/base/common/cancellation";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { CancellationError } from "vscode/vscode/vs/base/common/errors";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { posix } from "vscode/vscode/vs/base/common/path";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { WorkspaceFolder } from "vscode/vscode/vs/platform/workspace/common/workspace";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import * as fuzzyScorer from "vscode/vscode/vs/base/common/fuzzyScorer";
const { prepareQuery, scoreItemFuzzy, compareItemsByFuzzyScore } = fuzzyScorer;
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { quickPickItemScorerAccessor } from "vscode/vscode/vs/platform/quickinput/common/quickInput";
// @ts-expect-error The pinned package exposes this internal JS API without complete public typings.
import { match } from "vscode/vscode/vs/base/common/glob";
import { CodeStorage } from "./storage";
import * as monaco from "monaco-editor";
import { VSBuffer } from "vscode/vscode/vs/base/common/buffer";
import { ITextModelService } from "vscode/vscode/vs/editor/common/services/resolverService";

type State = {
  workspace: string;
  generation: string;
  active?: string;
  editors: { uri: string; dirty: boolean }[];
  history: string[];
};
let state: State = {
  workspace: "file:///workspace",
  generation: "",
  editors: [],
  history: [],
};
const pending = new Map<
  string,
  { resolve: Function; reject: Function; cleanup: () => void }
>();
const post = (body: object) =>
  (window as any).webkit.messageHandlers.toggleMessageHandler.postMessage({
    Event: "Workspace",
    ...body,
  });
function request(
  action: string,
  args: object = {},
  token: any = CancellationToken.None,
): Promise<any> {
  if (token.isCancellationRequested)
    return Promise.reject(new CancellationError());
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cancel();
      reject(new Error("Workspace request timed out"));
    }, 120000);
    const cancel = () => {
      pending.get(id)?.cleanup();
      pending.delete(id);
      post({ action: "cancel", id });
    };
    const subscription = token.onCancellationRequested(() => {
      cancel();
      reject(new CancellationError());
    });
    pending.set(id, {
      resolve,
      reject,
      cleanup: () => {
        clearTimeout(timer);
        subscription.dispose();
      },
    });
    post({ id, action, generation: state.generation, ...args });
  });
}
function proxy(service: any, overrides: any) {
  return new Proxy(service, {
    get(target, key) {
      const value =
        key in overrides
          ? Reflect.get(overrides, key)
          : Reflect.get(target, key);
      return typeof value === "function"
        ? value.bind(key in overrides ? overrides : target)
        : value;
    },
  });
}
function root() {
  return URI.parse(state.workspace);
}
function sameHost(uri: URI) {
  return uri.scheme === root().scheme && uri.authority === root().authority;
}
function inside(uri: URI) {
  return (
    sameHost(uri) &&
    (uri.path === root().path ||
      uri.path.startsWith(root().path.replace(/\/$/, "") + "/"))
  );
}
function inputs() {
  return state.editors.map((e) => ({ resource: URI.parse(e.uri) }));
}
const seen = () =>
  Array.from(new Set([...state.history, ...state.editors.map((e) => e.uri)]));
function configuration(original: any) {
  return proxy(original, {
    getValue(section?: any) {
      const base = original.getValue(
        typeof section === "object" ? section : undefined,
      );
      const value = {
        ...base,
        search: {
          exclude: { "**/node_modules": true, "**/bower_components": true },
          ...base.search,
          quickOpen: {
            includeSymbols: false,
            includeHistory: true,
            history: { filterSortOrder: "default" },
            ...base.search?.quickOpen,
          },
        },
        workbench: {
          ...base.workbench,
          editor: {
            ...base.workbench?.editor,
            enablePreviewFromQuickOpen: false,
          },
          quickOpen: { preserveInput: false, ...base.workbench?.quickOpen },
        },
      };
      return typeof section === "string"
        ? section.split(".").reduce((v, k) => v?.[k], value)
        : value;
    },
  });
}

function services(instantiation: any) {
  const get = (id: any) =>
    instantiation.invokeFunction((accessor: any) => accessor.get(id));
  const collection = new ServiceCollection();
  const fileIndexes = new Map<string, Promise<string[]>>();
  const group: any = {
    id: 1,
    isTransient: () => false,
    get editors() {
      return inputs();
    },
    openEditor: (input: any, options: any) =>
      editor.openEditor({ ...input, options }),
    closeEditor: async () => false,
  };
  const editor: any = proxy(get(IEditorService), {
    get editors() {
      return inputs();
    },
    get activeEditor() {
      return state.active ? { resource: URI.parse(state.active) } : undefined;
    },
    get activeTextEditorControl() {
      return CodeStorage.editor;
    },
    get activeEditorPane() {
      return state.active
        ? {
            input: editor.activeEditor,
            group,
            getControl: () => CodeStorage.editor,
          }
        : undefined;
    },
    async openEditor(input: any, options?: any) {
      const uri = input.resource;
      if (!uri) return undefined;
      let result;
      try {
        result = await request("open", {
          uri: uri.toString(),
          preserveFocus: !!input.options?.preserveFocus,
        });
      } catch (error) {
        // Native open reports filesystem failures and rejects stale navigation.
        if ((error as Error).name !== "Canceled") console.warn(error);
        return undefined;
      }
      state = result.state;
      const control = CodeStorage.editor;
      const selection = input.options?.selection ?? options?.selection;
      if (
        control &&
        selection &&
        control.getModel()?.uri.toString() === uri.toString()
      ) {
        control.setSelection({
          ...selection,
          endLineNumber: selection.endLineNumber ?? selection.startLineNumber,
          endColumn: selection.endColumn ?? selection.startColumn,
        });
        control.revealPositionInCenter({
          lineNumber: selection.startLineNumber,
          column: selection.startColumn,
        });
      }
      if (!input.options?.preserveFocus) control?.focus();
      return editor.activeEditorPane;
    },
  });
  collection.set(IEditorService, editor);
  collection.set(
    IEditorGroupsService,
    proxy(get(IEditorGroupsService), { groups: [group], activeGroup: group }),
  );
  collection.set(
    IHistoryService,
    proxy(get(IHistoryService), {
      getHistory: () => seen().map((uri) => ({ resource: URI.parse(uri) })),
      removeFromHistory(input: any) {
        const uri = input.resource.toString();
        state.history = state.history.filter((item) => item !== uri);
        void request("forget", { uri }).catch(console.error);
      },
    }),
  );
  collection.set(
    IWorkingCopyService,
    proxy(get(IWorkingCopyService), {
      isDirty: (uri: URI) =>
        state.editors.some((e) => e.uri === uri.toString() && e.dirty),
    }),
  );
  collection.set(
    IWorkspaceContextService,
    proxy(get(IWorkspaceContextService), {
      getWorkspace: () => ({
        id: state.generation,
        folders: [
          new WorkspaceFolder(
            { uri: root(), index: 0, name: posix.basename(root().path) },
            { path: root().path },
          ),
        ],
      }),
      getWorkspaceFolder: (uri: URI) =>
        inside(uri)
          ? new WorkspaceFolder(
              { uri: root(), index: 0, name: posix.basename(root().path) },
              { path: root().path },
            )
          : null,
      isInsideWorkspace: inside,
      getWorkbenchState: () => 2,
    }),
  );
  collection.set(
    IConfigurationService,
    configuration(get(IConfigurationService)),
  );
  collection.set(
    IPathService,
    proxy(get(IPathService), {
      path: Promise.resolve(posix),
      get defaultUriScheme() {
        return root().scheme;
      },
      userHome: async () => URI.parse((await request("home")).uri),
      fileURI: async (path: string) => root().with({ path }),
    }),
  );
  collection.set(
    ILabelService,
    proxy(get(ILabelService), {
      getUriLabel: (uri: URI, options: any) =>
        options?.relative && inside(uri)
          ? posix.relative(root().path, uri.path) || posix.basename(root().path)
          : uri.path,
    }),
  );
  collection.set(
    IFileService,
    proxy(get(IFileService), {
      hasProvider: sameHost,
      async readFile(uri: URI) {
        const result = await request("read", { uri: uri.toString() });
        return {
          resource: uri,
          name: posix.basename(uri.path),
          value: VSBuffer.fromString(result.text),
        };
      },
      async stat(uri: URI) {
        const value = await request("stat", { uri: uri.toString() });
        return {
          resource: uri,
          name: posix.basename(uri.path),
          isFile: value.type === "file",
          isDirectory: value.type === "directory",
          isSymbolicLink: value.type === "symlink",
          size: value.size,
          mtime: value.mtime,
          ctime: value.mtime,
        };
      },
    }),
  );
  collection.set(
    ISearchService,
    proxy(get(ISearchService), {
      async fileSearch(query: any, token: any = CancellationToken.None) {
        const empty = { results: [], limitHit: false, messages: [] };
        if (token.isCancellationRequested) return empty;
        const generation = state.generation;
        const patterns = {
          ...query.excludePattern,
          ...query.folderQueries?.[0]?.excludePattern,
        };
        const excludedDirectories = Object.entries(patterns).flatMap(
          ([pattern, excluded]) => {
            const found = /^\*\*\/([^/*?{}]+)(?:\/\*\*)?$/.exec(pattern);
            return excluded === true && found ? [found[1]] : [];
          },
        );
        const indexKey = JSON.stringify([generation, query.cacheKey, excludedDirectories]);
        let index = fileIndexes.get(indexKey);
        if (!index) {
          // One shared native index request serves all keystrokes in this picker.
          // Individual canceled queries do not cancel the shared cache warm-up.
          index = request("files", { excludedDirectories }).then(result => result.files as string[]);
          fileIndexes.set(indexKey, index);
          index.catch(() => fileIndexes.delete(indexKey));
        }
        let files: string[];
        try {
          files = await index;
        } catch (error) {
          if (
            token.isCancellationRequested ||
            (error as Error).name === "Canceled"
          )
            return empty;
          return {
            ...empty,
            messages: [{ text: (error as Error).message, type: 2 }],
          };
        }
        if (generation !== state.generation || token.isCancellationRequested)
          return empty;
        const resources = Array.from(
          new Set([
            ...files,
            ...(query.extraFileResources ?? []).map((u: URI) => u.toString()),
          ]),
        );
        const prepared = prepareQuery(query.filePattern ?? "");
        const cache = Object.create(null);
        const picks = resources
          .map((value) => {
            const resource = URI.parse(value);
            const relative = posix.relative(root().path, resource.path);
            return {
              resource,
              label: posix.basename(resource.path),
              description: posix.dirname(relative),
              relative,
            };
          })
          .filter((pick) => {
            const folderQuery = query.folderQueries?.find((f: any) =>
              pick.resource.path.startsWith(
                f.folder.path.replace(/\/$/, "") + "/",
              ),
            );
            const exclusions = {
              ...query.excludePattern,
              ...folderQuery?.excludePattern,
            };
            const includes =
              folderQuery?.includePattern ?? query.includePattern;
            return (
              !match(exclusions, pick.relative) &&
              (!includes || match(includes, pick.relative)) &&
              (!prepared.normalized ||
                scoreItemFuzzy(
                  pick,
                  prepared,
                  true,
                  quickPickItemScorerAccessor,
                  cache,
                ).score > 0)
            );
          });
        if (prepared.normalized)
          picks.sort((a, b) =>
            compareItemsByFuzzyScore(
              a,
              b,
              prepared,
              true,
              quickPickItemScorerAccessor,
              cache,
            ),
          );
        const max = query.maxResults || picks.length;
        return {
          results: picks
            .slice(0, max)
            .map((pick) => ({ resource: pick.resource })),
          limitHit: picks.length > max,
          messages: [],
        };
      },
      clearCache: async (cacheKey: string) => {
        for (const key of fileIndexes.keys()) {
          if (JSON.parse(key)[1] === cacheKey) fileIndexes.delete(key);
        }
      },
    }),
  );
  return collection;
}

export function installWorkspaceQuickAccess() {
  (window as any).codeAppWorkspace = {
    receive(id: string, result: any, error?: string) {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      entry.cleanup();
      error
        ? entry.reject(
            error === "Canceled" ? new CancellationError() : new Error(error),
          )
        : entry.resolve(result);
    },
    show: () => StandaloneServices.get(IQuickInputService).quickAccess.show(""),
    showCommands: () =>
      StandaloneServices.get(IQuickInputService).quickAccess.show(">"),
    // Exposed for integration checks; the provider is the stock VS Code class.
    provider: AnythingQuickAccessProvider.name,
  };
  StandaloneServices.get(ITextModelService).registerTextModelContentProvider(
    "file",
    {
      async provideTextContent(uri: URI) {
        const existing = monaco.editor.getModel(uri);
        if (existing) return existing;
        state = await request("snapshot");
        if (!sameHost(uri)) return null;
        try {
          const result = await request("read", { uri: uri.toString() });
          return monaco.editor.getModel(uri) ?? monaco.editor.createModel(result.text, undefined, uri);
        } catch {
          // Let other providers resolve virtual files owned by language extensions.
          return null;
        }
      },
    },
  );
  const instantiation = StandaloneServices.get(IInstantiationService);
  class NativeAnythingProvider {
    private provider: any;
    private child: any;
    get defaultFilterValue() {
      return this.provider?.defaultFilterValue;
    }
    provide(picker: any, token: any, options: any) {
      const disposables = new DisposableStore();
      picker.busy = true;
      request("snapshot", {}, token)
        .then((snapshot) => {
          if (token.isCancellationRequested) return;
          state = snapshot;
          if (!this.provider) {
            // VS Code keeps this provider for the service lifetime. Disposing its
            // throttled searches when a picker closes rejects pending promises.
            this.child = instantiation.createChild(services(instantiation));
            this.provider = this.child.createInstance(AnythingQuickAccessProvider);
          }
          disposables.add(this.provider.provide(picker, token, options));
        })
        .catch((error) => {
          if (!token.isCancellationRequested) {
            picker.items = [
              {
                label: "Unable to access workspace",
                description: error.message,
              },
            ];
            console.error(error);
          }
        })
        .finally(() => {
          picker.busy = false;
        });
      return disposables;
    }
  }
  (Registry.as(Extensions.Quickaccess) as any).registerQuickAccessProvider({
    ctor: NativeAnythingProvider,
    prefix: "",
    contextKey: "inFilesPicker",
    placeholder: "Search files by name",
    helpEntries: [
      { description: "Go to File", commandId: "workbench.action.quickOpen" },
    ],
  });
}
