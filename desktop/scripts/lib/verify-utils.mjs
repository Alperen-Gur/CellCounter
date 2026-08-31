import { readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

const SCRIPT_DIR = dirname(dirname(fileURLToPath(import.meta.url)));

export const DESKTOP_ROOT = resolve(SCRIPT_DIR, "..");
export const REPOSITORY_ROOT = resolve(DESKTOP_ROOT, "..");

export function fail(message) {
  throw new Error(message);
}

export function assert(condition, message) {
  if (!condition) fail(message);
}

export function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    fail(`${message}: expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  }
}

export function assertString(value, message) {
  assert(typeof value === "string" && value.trim().length > 0, message);
}

export function assertIncludes(source, fragment, message) {
  assert(source.includes(fragment), `${message}: missing ${JSON.stringify(fragment)}`);
}

export function assertSameMembers(actual, expected, message) {
  const left = [...actual].sort();
  const right = [...expected].sort();
  assertEqual(JSON.stringify(left), JSON.stringify(right), message);
}

export function readText(relativePath) {
  return readFileSync(resolve(DESKTOP_ROOT, relativePath), "utf8");
}

export function readRepositoryText(relativePath) {
  return readFileSync(resolve(REPOSITORY_ROOT, relativePath), "utf8");
}

export function readJson(relativePath) {
  return JSON.parse(readText(relativePath));
}

export function assertFile(relativePath, message = `Required file is missing: ${relativePath}`) {
  const stats = statSync(resolve(DESKTOP_ROOT, relativePath));
  assert(stats.isFile() && stats.size > 0, message);
}

export async function importTypeScriptModule(relativePath) {
  const sourcePath = resolve(DESKTOP_ROOT, relativePath);
  const source = readFileSync(sourcePath, "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2022,
      isolatedModules: true,
    },
    fileName: sourcePath,
    reportDiagnostics: true,
  });
  const errors = (output.diagnostics ?? []).filter(
    (diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error,
  );
  assert(errors.length === 0, `TypeScript transpilation failed for ${relativePath}`);
  const encoded = Buffer.from(`${output.outputText}\n//# sourceURL=${pathToFileURL(sourcePath).href}`).toString("base64");
  return import(`data:text/javascript;base64,${encoded}`);
}

export function reportFailure(error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Verification failed: ${message}`);
  process.exitCode = 1;
}

export function repositoryPath(...segments) {
  return join(REPOSITORY_ROOT, ...segments);
}
