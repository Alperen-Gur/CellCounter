// Release staging only. This script never downloads or runs a model/runtime.
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== "--output") throw new Error("Use build.mjs --output <new compiled-assets directory>.");
const output = resolve(args[1]);
const require = createRequire(resolve(root, "desktop/package.json"));
const ts = require("typescript");
const hash = (data) => createHash("sha256").update(data).digest("hex");
const configPath = resolve(root, "shared/microscopy-worker/tsconfig.json");
const config = ts.readConfigFile(configPath, ts.sys.readFile);
if (config.error) throw new Error(ts.flattenDiagnosticMessageText(config.error.messageText, "\n"));
const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, dirname(configPath));
const program = ts.createProgram(parsed.fileNames, parsed.options);
const diagnostics = [...parsed.errors, ...ts.getPreEmitDiagnostics(program)];
if (diagnostics.length) throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
  getCanonicalFileName: name => name, getCurrentDirectory: () => root, getNewLine: () => "\n",
}));
await mkdir(output, { recursive: false });
const engine = ["types", "guards", "zarr", "registration", "workspace", "paint", "lineage", "project", "animation"];
const worker = ["protocol", "catalogue", "io", "worker"];
const files = [], sources = [];
for (const [folder, names] of [["microscopy", engine], ["microscopy-worker", worker]]) {
  await mkdir(resolve(output, folder));
  for (const name of names) {
    const sourcePath = `shared/${folder}/${name}.ts`; const source = await readFile(resolve(root, sourcePath), "utf8");
    const transformer = (context) => {
      const specifier = (node) => ts.isStringLiteral(node) && node.text.startsWith(".") ? ts.factory.createStringLiteral(`${node.text}.mjs`) : node;
      const visit = (node) => {
        if (ts.isImportDeclaration(node)) return ts.factory.updateImportDeclaration(node, node.modifiers, node.importClause, specifier(node.moduleSpecifier), node.attributes);
        if (ts.isExportDeclaration(node) && node.moduleSpecifier) return ts.factory.updateExportDeclaration(node, node.modifiers, node.isTypeOnly, node.exportClause, specifier(node.moduleSpecifier), node.attributes);
        return ts.visitEachChild(node, visit, context);
      };
      return (node) => ts.visitNode(node, visit);
    };
    const compiled = ts.transpileModule(source, { fileName: sourcePath, compilerOptions: {
      target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, strict: true, isolatedModules: true,
      sourceMap: false, removeComments: false }, transformers: { before: [transformer] } }).outputText;
    const path = `${folder}/${name}.mjs`;
    await writeFile(resolve(output, path), compiled, { flag: "wx" });
    files.push({ path, sha256: hash(compiled), bytes: Buffer.byteLength(compiled) });
    sources.push({ path: sourcePath, sha256: hash(source) });
  }
}
const { catalogue } = await import(pathToFileURL(resolve(output, "microscopy-worker/catalogue.mjs")).href);
const descriptor = `${JSON.stringify(catalogue(), null, 2)}\n`;
await writeFile(resolve(output, "microscopy-worker/catalogue.json"), descriptor, { flag: "wx" });
files.push({ path: "microscopy-worker/catalogue.json", sha256: hash(descriptor), bytes: Buffer.byteLength(descriptor) });
await writeFile(resolve(output, "microscopy-build.json"), `${JSON.stringify({ schemaVersion: 1, engineVersion: "microscopy-worker-1",
  nodeVersion: "24.22.0", entrypoint: "microscopy-worker/worker.mjs", compiler: { name: "typescript", version: ts.version }, sources, files }, null, 2)}\n`, { flag: "wx" });
