// Swift <-> Monaco bridge.
//
// Swift → JS : window.harness.receive(<JSON string>)   (via evaluateJavaScript)
// JS → Swift : window.webkit.messageHandlers.harness.postMessage(<object>)
//
// Every message has a `type`. Requests that expect an answer carry `requestId`
// and are answered with { type: "response", requestId, ... }.
//
// The Swift side is HarnessEditor/Sources/HarnessEditor/MonacoBridge.swift –
// keep the two message enums in sync.

import * as monaco from "monaco-editor";
import editorWorker from "worker:editor";
import tsWorker from "worker:ts";
import jsonWorker from "worker:json";
import cssWorker from "worker:css";
import htmlWorker from "worker:html";

// ---------- Workers (inlined, started from Blob URLs) ----------

const workerSources: Record<string, string> = {
  editorWorkerService: editorWorker,
  typescript: tsWorker,
  javascript: tsWorker,
  json: jsonWorker,
  css: cssWorker,
  scss: cssWorker,
  less: cssWorker,
  html: htmlWorker,
  handlebars: htmlWorker,
  razor: htmlWorker,
};

const workerUrls = new Map<string, string>();
function workerUrl(label: string): string {
  const src = workerSources[label] ?? workerSources.editorWorkerService;
  let url = workerUrls.get(src);
  if (!url) {
    url = URL.createObjectURL(new Blob([src], { type: "text/javascript" }));
    workerUrls.set(src, url);
  }
  return url;
}

(self as any).MonacoEnvironment = {
  getWorker(_: string, label: string) {
    return new Worker(workerUrl(label));
  },
};

// ---------- Messaging ----------

type Marker = {
  line: number;
  column: number;
  endLine?: number;
  endColumn?: number;
  message: string;
  severity: "error" | "warning" | "info" | "hint";
  source?: string;
};

type Inbound =
  | { type: "openModel"; id: string; path: string; language?: string; text: string }
  | { type: "closeModel"; id: string }
  | { type: "activate"; id: string }
  | { type: "setContent"; id: string; text: string }
  | { type: "getContent"; id: string; requestId: string }
  | { type: "setMarkers"; id: string; markers: Marker[] }
  | { type: "revealLine"; id: string; line: number; column?: number }
  | { type: "showDiff"; id: string; path: string; language?: string; original: string; modified: string }
  | { type: "hideDiff" }
  | { type: "getDiffHunks"; requestId: string }
  | { type: "applyHunk"; index: number; direction: "revert" | "accept"; requestId: string }
  | { type: "runAction"; action: string }
  | { type: "setTheme"; dark: boolean }
  | { type: "setOptions"; options: monaco.editor.IEditorOptions }
  | { type: "focus" };

type Outbound =
  | { type: "ready" }
  | { type: "contentChanged"; id: string; version: number; text: string }
  | { type: "selectionChanged"; id: string; startLine: number; startColumn: number; endLine: number; endColumn: number; text: string }
  | { type: "cursor"; id: string; line: number; column: number }
  | { type: "save"; id: string }
  | { type: "response"; requestId: string; [k: string]: unknown }
  | { type: "log"; level: "info" | "error"; message: string };

function post(msg: Outbound) {
  (window as any).webkit?.messageHandlers?.harness?.postMessage(msg);
}

function log(level: "info" | "error", message: string) {
  post({ type: "log", level, message });
}

// ---------- Editor setup ----------

const editorHost = document.getElementById("editor")!;
const diffHost = document.getElementById("diff")!;

const baseOptions: monaco.editor.IStandaloneEditorConstructionOptions = {
  automaticLayout: true,
  fontFamily: "SF Mono, Menlo, Monaco, monospace",
  fontSize: 13,
  lineHeight: 20,
  minimap: { enabled: false },
  scrollBeyondLastLine: false,
  renderLineHighlight: "line",
  smoothScrolling: true,
  cursorBlinking: "smooth",
  folding: true,
  bracketPairColorization: { enabled: true },
  multiCursorModifier: "alt",
  tabSize: 2,
  padding: { top: 8 },
  scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10, useShadows: false },
};

const editor = monaco.editor.create(editorHost, { ...baseOptions, model: null });
let diffEditor: monaco.editor.IStandaloneDiffEditor | null = null;

const models = new Map<string, monaco.editor.ITextModel>();
const viewStates = new Map<string, monaco.editor.ICodeEditorViewState | null>();
let activeId: string | null = null;
let contentTimer: number | null = null;

// ⌘S inside the web view → Swift saves the active model.
editor.addAction({
  id: "harness.save",
  label: "Save",
  keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS],
  run: () => {
    if (activeId) post({ type: "save", id: activeId });
  },
});

editor.onDidChangeModelContent(() => {
  const id = activeId;
  const model = editor.getModel();
  if (!id || !model) return;
  if (contentTimer !== null) window.clearTimeout(contentTimer);
  contentTimer = window.setTimeout(() => {
    contentTimer = null;
    post({ type: "contentChanged", id, version: model.getVersionId(), text: model.getValue() });
  }, 60);
});

editor.onDidChangeCursorSelection((e) => {
  const model = editor.getModel();
  if (!activeId || !model) return;
  const s = e.selection;
  post({
    type: "selectionChanged",
    id: activeId,
    startLine: s.startLineNumber,
    startColumn: s.startColumn,
    endLine: s.endLineNumber,
    endColumn: s.endColumn,
    text: s.isEmpty() ? "" : model.getValueInRange(s),
  });
});

editor.onDidChangeCursorPosition((e) => {
  if (!activeId) return;
  post({ type: "cursor", id: activeId, line: e.position.lineNumber, column: e.position.column });
});

function languageFor(path: string, explicit?: string): string {
  if (explicit) return explicit;
  const ext = path.slice(path.lastIndexOf(".")).toLowerCase();
  for (const lang of monaco.languages.getLanguages()) {
    if (lang.extensions?.includes(ext)) return lang.id;
  }
  return "plaintext";
}

function activate(id: string) {
  const model = models.get(id);
  if (!model) return;
  if (activeId && activeId !== id) viewStates.set(activeId, editor.saveViewState());
  activeId = id;
  editor.setModel(model);
  const vs = viewStates.get(id);
  if (vs) editor.restoreViewState(vs);
  editor.focus();
}

const severityMap: Record<Marker["severity"], monaco.MarkerSeverity> = {
  error: monaco.MarkerSeverity.Error,
  warning: monaco.MarkerSeverity.Warning,
  info: monaco.MarkerSeverity.Info,
  hint: monaco.MarkerSeverity.Hint,
};

function handle(msg: Inbound) {
  switch (msg.type) {
    case "openModel": {
      let model = models.get(msg.id);
      if (!model) {
        const uri = monaco.Uri.file(msg.path);
        model = monaco.editor.getModel(uri) ?? monaco.editor.createModel(msg.text, languageFor(msg.path, msg.language), uri);
        models.set(msg.id, model);
      } else if (model.getValue() !== msg.text) {
        model.setValue(msg.text);
      }
      activate(msg.id);
      break;
    }
    case "closeModel": {
      const model = models.get(msg.id);
      models.delete(msg.id);
      viewStates.delete(msg.id);
      if (activeId === msg.id) {
        activeId = null;
        editor.setModel(null);
      }
      model?.dispose();
      break;
    }
    case "activate":
      activate(msg.id);
      break;
    case "setContent": {
      const model = models.get(msg.id);
      if (!model) return;
      // Preserve undo stack + cursor when content is replaced from disk.
      const full = model.getFullModelRange();
      model.pushEditOperations([], [{ range: full, text: msg.text }], () => null);
      break;
    }
    case "getContent": {
      const model = models.get(msg.id);
      post({ type: "response", requestId: msg.requestId, text: model?.getValue() ?? null });
      break;
    }
    case "setMarkers": {
      const model = models.get(msg.id);
      if (!model) return;
      monaco.editor.setModelMarkers(
        model,
        "harness",
        msg.markers.map((m) => ({
          startLineNumber: m.line,
          startColumn: m.column,
          endLineNumber: m.endLine ?? m.line,
          endColumn: m.endColumn ?? m.column + 1,
          message: m.message,
          severity: severityMap[m.severity],
          source: m.source,
        })),
      );
      break;
    }
    case "revealLine": {
      activate(msg.id);
      const pos = { lineNumber: msg.line, column: msg.column ?? 1 };
      editor.setPosition(pos);
      editor.revealPositionInCenter(pos, monaco.editor.ScrollType.Smooth);
      editor.focus();
      break;
    }
    case "showDiff": {
      editorHost.hidden = true;
      diffHost.hidden = false;
      if (!diffEditor) {
        diffEditor = monaco.editor.createDiffEditor(diffHost, {
          ...baseOptions,
          renderSideBySide: true,
          originalEditable: false,
          readOnly: false,
          ignoreTrimWhitespace: false,
        });
        diffEditor.getModifiedEditor().onDidChangeModelContent(() => {
          diffDirty = true;
          const m = diffEditor?.getModel()?.modified;
          if (m && currentDiffId)
            post({ type: "contentChanged", id: currentDiffId, version: m.getVersionId(), text: m.getValue() });
        });
        diffEditor.onDidUpdateDiff(() => {
          diffDirty = false;
        });
      }
      const lang = languageFor(msg.path, msg.language);
      diffEditor.getModel()?.original.dispose();
      diffEditor.getModel()?.modified.dispose();
      diffEditor.setModel({
        original: monaco.editor.createModel(msg.original, lang),
        modified: monaco.editor.createModel(msg.modified, lang),
      });
      currentDiffId = msg.id;
      diffDirty = true;
      break;
    }
    case "hideDiff":
      diffHost.hidden = true;
      editorHost.hidden = false;
      currentDiffId = null;
      editor.layout();
      break;
    case "getDiffHunks": {
      // The diff is recomputed asynchronously after setModel / edits, so getLineChanges() is
      // null or stale until onDidUpdateDiff fires. Wait for it (bounded) so Swift never acts on
      // stale hunk indices.
      let answered = false;
      const respond = () => {
        if (answered) return;
        answered = true;
        const changes = diffEditor?.getLineChanges() ?? [];
        post({
          type: "response",
          requestId: msg.requestId,
          hunks: changes.map((c, index) => ({
            index,
            originalStart: c.originalStartLineNumber,
            originalEnd: c.originalEndLineNumber,
            modifiedStart: c.modifiedStartLineNumber,
            modifiedEnd: c.modifiedEndLineNumber,
          })),
        });
      };
      if (diffEditor && (diffDirty || diffEditor.getLineChanges() === null)) {
        const sub = diffEditor.onDidUpdateDiff(() => {
          sub.dispose();
          respond();
        });
        window.setTimeout(() => {
          sub.dispose();
          respond();
        }, 1500);
      } else {
        respond();
      }
      break;
    }
    case "applyHunk": {
      const ok = applyHunk(msg.index, msg.direction);
      post({ type: "response", requestId: msg.requestId, ok });
      break;
    }
    case "runAction":
      editor.getAction(msg.action)?.run();
      break;
    case "setTheme":
      monaco.editor.setTheme(msg.dark ? "vs-dark" : "vs");
      break;
    case "setOptions":
      editor.updateOptions(msg.options);
      diffEditor?.updateOptions(msg.options);
      break;
    case "focus":
      editor.focus();
      break;
  }
}

let currentDiffId: string | null = null;
// True from a model swap / modified-side edit until the diff editor reports a fresh diff.
let diffDirty = false;

// Revert one hunk: copy the original lines back over the modified range.
// Accept is a no-op on the modified buffer (it already contains the change) and
// exists so Swift can drive per-hunk bookkeeping symmetrically.
function applyHunk(index: number, direction: "revert" | "accept"): boolean {
  if (!diffEditor) return false;
  const changes = diffEditor.getLineChanges() ?? [];
  const c = changes[index];
  const model = diffEditor.getModel();
  if (!c || !model) return false;
  if (direction === "accept") return true;

  const { original, modified } = model;
  const originalText =
    c.originalEndLineNumber === 0
      ? ""
      : original.getValueInRange({
          startLineNumber: c.originalStartLineNumber,
          startColumn: 1,
          endLineNumber: c.originalEndLineNumber,
          endColumn: original.getLineMaxColumn(c.originalEndLineNumber),
        });

  let range: monaco.IRange;
  let text = originalText;
  if (c.modifiedEndLineNumber === 0) {
    // Pure deletion in modified: insert original lines after modifiedStart.
    const line = c.modifiedStartLineNumber;
    const col = line === 0 ? 1 : modified.getLineMaxColumn(line);
    range = { startLineNumber: Math.max(line, 1), startColumn: col, endLineNumber: Math.max(line, 1), endColumn: col };
    text = line === 0 ? originalText + "\n" : "\n" + originalText;
  } else {
    range = {
      startLineNumber: c.modifiedStartLineNumber,
      startColumn: 1,
      endLineNumber: c.modifiedEndLineNumber,
      endColumn: modified.getLineMaxColumn(c.modifiedEndLineNumber),
    };
  }
  modified.pushEditOperations([], [{ range, text }], () => null);
  return true;
}

(window as any).harness = {
  receive(json: string) {
    try {
      handle(JSON.parse(json) as Inbound);
    } catch (e) {
      log("error", `bridge: ${(e as Error).message}`);
    }
  },
};

// Default to system appearance; Swift sends setTheme on launch and on change.
monaco.editor.setTheme(window.matchMedia("(prefers-color-scheme: dark)").matches ? "vs-dark" : "vs");
post({ type: "ready" });
