/** On-demand allowlist only. Never accept logs, identifiers or whole app state. */
export interface DiagnosticSnapshot {
  imageCount?: number;
  batchCount?: number;
  reviewCandidateCount?: number;
  processingJobCount?: number;
  storageAvailable?: boolean;
  reviewIndexing?: boolean;
  reviewIndexFailed?: boolean;
  detectionErrorPresent?: boolean;
}
export const DIAGNOSTICS_FILENAME = "CellCounter-diagnostics.txt";
export const MAX_DIAGNOSTICS_BYTES = 64 * 1024;

function countBand(value: unknown): string {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return "unknown";
  if (value === 0) return "0";
  if (value <= 10) return "1–10";
  if (value <= 100) return "11–100";
  if (value <= 1000) return "101–1,000";
  return "over 1,000";
}

export function buildLocalDiagnostics(platform: "windows" | "web", version: string, snapshot?: DiagnosticSnapshot): string {
  const safeVersion = /^\d{1,4}\.\d{1,4}\.\d{1,4}$/.test(version) ? version : "unknown";
  const lines = ["CellCounter local diagnostics · format 1", "", `Application version: ${safeVersion}`,
    `Platform: ${platform === "windows" ? "Windows" : "Browser"}`, "",
    "Prepared locally on request. Recording requires explicit opt-in. No automatic uploads.",
    "Excluded: images, measurements, names, IDs, paths, logs, crash dumps, device identifiers, network details and timestamps."];
  if (snapshot) {
    lines.push("", "Optional state snapshot (cached; may be stale or incomplete):", "Counts are ranges, not exact totals.");
    for (const [key, label] of [["imageCount", "Library images"], ["batchCount", "Library batches"],
      ["reviewCandidateCount", "Review candidates"], ["processingJobCount", "Saved processing jobs"]] as const) {
      if (snapshot[key] !== undefined) lines.push(`${label}: ${countBand(snapshot[key])}`);
    }
    for (const [key, label] of [["storageAvailable", "Local repository ready"], ["reviewIndexing", "Review index building"],
      ["reviewIndexFailed", "Review index error present"], ["detectionErrorPresent", "Detection error present"]] as const) {
      if (typeof snapshot[key] === "boolean") lines.push(`${label}: ${snapshot[key] ? "yes" : "no"}`);
    }
  }
  lines.push("", "This snapshot does not reproduce a crash or diagnose its cause.", "");
  return lines.join("\n");
}

export function diagnosticExportAllowed(text: string): boolean {
  return text.trim().length > 0 && new TextEncoder().encode(text).byteLength <= MAX_DIAGNOSTICS_BYTES;
}
