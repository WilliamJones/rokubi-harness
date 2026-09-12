// Builds the Monaco bundle that ships inside RokubiHarness.app.
//
// Output: dist/
//   editor.html   – host page loaded by WKWebView via loadFileURL
//   bridge.js     – Monaco + Swift<->JS bridge (single file, workers inlined as blobs)
//   bridge.css    – Monaco styles (codicon font embedded as data URL)
//
// Workers are bundled first, then embedded as text into bridge.js so that they
// can be started from a Blob URL. This avoids file:// worker restrictions inside
// WKWebView and keeps the bundle fully offline.
import { build } from "esbuild";
import { mkdir, cp, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, "dist");
const workersDir = join(here, ".workers");

await rm(dist, { recursive: true, force: true });
await rm(workersDir, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
await mkdir(workersDir, { recursive: true });

const monacoEsm = join(here, "node_modules/monaco-editor/esm/vs");
const workers = {
  editor: join(monacoEsm, "editor/editor.worker.js"),
  ts: join(monacoEsm, "language/typescript/ts.worker.js"),
  json: join(monacoEsm, "language/json/json.worker.js"),
  css: join(monacoEsm, "language/css/css.worker.js"),
  html: join(monacoEsm, "language/html/html.worker.js"),
};

// 1. Workers → .workers/<name>.worker.js
await build({
  entryPoints: Object.fromEntries(
    Object.entries(workers).map(([name, path]) => [`${name}.worker`, path]),
  ),
  bundle: true,
  minify: true,
  format: "iife",
  outdir: workersDir,
  logLevel: "warning",
});

// 2. Bridge → dist/bridge.js (+ bridge.css), workers imported as text.
await build({
  entryPoints: [join(here, "src/bridge.ts")],
  bundle: true,
  minify: true,
  sourcemap: false,
  format: "iife",
  target: ["safari17"],
  outfile: join(dist, "bridge.js"),
  loader: {
    ".ttf": "dataurl",
    ".workerjs": "text",
  },
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [
    {
      // `import src from "worker:ts"` → contents of .workers/ts.worker.js
      name: "worker-text",
      setup(b) {
        b.onResolve({ filter: /^worker:/ }, (args) => ({
          path: join(workersDir, `${args.path.slice("worker:".length)}.worker.js`),
          namespace: "worker-text",
        }));
        b.onLoad({ filter: /.*/, namespace: "worker-text" }, async (args) => ({
          contents: await (await import("node:fs/promises")).readFile(args.path, "utf8"),
          loader: "text",
        }));
      },
    },
  ],
  logLevel: "warning",
});

await cp(join(here, "src/editor.html"), join(dist, "editor.html"));
await rm(workersDir, { recursive: true, force: true });
console.log("monaco bundle written to", dist);
