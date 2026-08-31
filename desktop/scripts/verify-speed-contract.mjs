import {
  assert,
  assertIncludes,
  readText,
  reportFailure,
} from "./lib/verify-utils.mjs";

try {
  const editor = readText("src/pages/results/editing/useMaskEditor.ts");
  assertIncludes(editor, "let commitQueue: Promise<void>", "mask edits must be ordered");
  assertIncludes(editor, "port.commitCellEdit(", "mask edits must use the atomic command");
  assert(!editor.includes("port.saveDetection("), "mask edits must not separately save detections");
  assert(!editor.includes("port.recordCorrection("), "mask edits must not issue per-row correction IPC");

  const library = readText("src/pages/library/useLibraryData.ts");
  assertIncludes(library, ".detectionSummaries(", "Library must use contour-free summaries");
  assert(!library.includes(".getDetections("), "Library must not transfer full contours");

  const results = readText("src/pages/results/useResultsData.ts");
  assertIncludes(results, ".imagesForBatch(", "Results must use a batch-scoped image query");
  assert(!results.includes(".allImages("), "Results must not load the whole image library");

  const repo = readText("src-tauri/src/db/repo.rs");
  assertIncludes(repo, "pub fn commit_cell_edit(", "atomic edit command must exist");
  assertIncludes(repo, "let tx = conn.transaction()", "atomic edit command must open one transaction");
  assertIncludes(repo, "for correction in corrections", "corrections must be inserted as one batch");
  assertIncludes(repo, ".chunks(SQLITE_IN_CHUNK)", "large scoped reads must stay below SQLite limits");

  const importer = readText("src-tauri/src/images/importer.rs");
  assert(!importer.includes("std::fs::read(&stored_path)"), "import metadata must not read the full file");
  assertIncludes(importer, "MAX_IMAGE_DESCRIPTION_BYTES", "metadata descriptions must be capped");
  assertIncludes(importer, "decoder.total_bytes()", "decoded bytes must be checked before materialization");

  console.log("Windows speed contract verification passed");
} catch (error) {
  reportFailure(error);
}
