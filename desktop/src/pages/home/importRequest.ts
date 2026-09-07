type ImportKind = "images" | "folder";
let pending: ImportKind | undefined;
export function requestImageImport(kind: ImportKind) {
  pending = kind;
  window.dispatchEvent(new Event("cc:request-import"));
}
export function takeImageImportRequest(): ImportKind | undefined {
  const kind = pending; pending = undefined; return kind;
}
