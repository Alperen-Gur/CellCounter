import type { ProjectSnapshot } from "./protocol";

export const catalogueNames = {
  jobs: "Workflow jobs", sweeps: "Parameter sweeps", jobWorkers: "Background workers", imageExports: "Image exports",
  displayPresets: "Display presets", distributions: "Distributed work", refreshJobs: "Result refresh plans",
  collections: "Image collections", zarrSources: "NGFF sources", tiledAnalyses: "Tiled analyses",
  statisticsDesigns: "Statistical designs", statisticsRuns: "Statistical results", workspaces: "Layer workspaces",
  workspaceOutputs: "Workspace outputs", labelImports: "Imported masks", workflows: "Saved workflows",
  experimentLayouts: "Experiment layouts", experimentApplications: "Applied layouts", acquisitionSessions: "Acquisition sessions",
  experimentExclusions: "Reasoned exclusions", plugins: "Installed plugins", adaptationDatasets: "Reference datasets",
  models: "Registered models", trainingJobs: "Training jobs", assayRuns: "Assay results", assaySeriesRuns: "Assay time series",
  reviewSessions: "Review sessions", largeSources: "TIFF sources", specimens: "Biological specimens", plates: "Plates", assignments: "Image assignments",
} as const;
export type CatalogueKey = keyof typeof catalogueNames;
export type CatalogueEntry = Record<string, unknown>;
export type CatalogueRef = { catalogue: CatalogueKey; entryId: string; version?: number };
export type CataloguePin = CatalogueRef & { entry?: CatalogueEntry; missing?: boolean };
export type CataloguePageInfo = { total: number; returned: number; nextCursor: string | null; partial: boolean };
export type CataloguePage<T = CatalogueEntry> = CataloguePageInfo & { catalogue: CatalogueKey; entries: T[]; sourceRevision: number };
export type CatalogueMany<T = CatalogueEntry> = { catalogue: CatalogueKey; entries: T[]; missingIds: string[]; sourceRevision: number };
export function catalogueEntryId(catalogue: CatalogueKey, entry: CatalogueEntry): string {
  if (catalogue === "experimentExclusions") return `${entry.target}:${entry.targetId}`;
  if (catalogue === "assignments") return String(entry.imageId ?? "");
  return String(entry.id ?? entry.runId ?? entry.pluginId ?? entry.exportId ?? entry.importId ?? entry.workerId ?? entry.imageId ?? "");
}
export function catalogueLabel(catalogue: CatalogueKey, entry: CatalogueEntry): string {
  const manifest = entry.manifest as { name?: string; version?: string } | undefined;
  const name = String(entry.name ?? entry.instanceName ?? manifest?.name ?? entry.label ?? entry.assay ?? entry.targetId ?? catalogueEntryId(catalogue, entry));
  return `${name}${entry.version != null ? ` · v${entry.version}` : manifest?.version ? ` · v${manifest.version}` : ""}${entry.status ? ` · ${entry.status}` : ""}`;
}
export function catalogueEntries(snapshot: ProjectSnapshot, catalogue: CatalogueKey): CatalogueEntry[] {
  if (catalogue === "specimens" || catalogue === "plates" || catalogue === "assignments")
    return (snapshot.experimentalDesign?.[catalogue] ?? []) as unknown as CatalogueEntry[];
  if (catalogue === "experimentExclusions") return Object.entries(snapshot.experimentExclusions ?? {}).flatMap(([target, entries]) =>
    Object.values(entries).map(entry => ({ ...entry, target })));
  return ((snapshot as unknown as Record<string, unknown>)[catalogue] ?? []) as CatalogueEntry[];
}
/** Add an exact descriptor without treating any page as a complete scientific scope. */
export function mergeCatalogueEntry(snapshot: ProjectSnapshot, catalogue: CatalogueKey, entry: CatalogueEntry): ProjectSnapshot {
  const id = catalogueEntryId(catalogue, entry);
  if (catalogue === "experimentExclusions") {
    const target = entry.target as "image" | "specimen", targetId = String(entry.targetId);
    const values = { ...snapshot.experimentExclusions?.[target] };
    if (entry.excluded) values[targetId] = entry as unknown as NonNullable<ProjectSnapshot["experimentExclusions"]>[typeof target][string];
    else delete values[targetId];
    return { ...snapshot, experimentExclusions: { image: {}, specimen: {}, ...snapshot.experimentExclusions, [target]: values } };
  }
  const entries = [...catalogueEntries(snapshot, catalogue).filter(value => catalogueEntryId(catalogue, value) !== id), entry];
  if (catalogue === "specimens" || catalogue === "plates" || catalogue === "assignments")
    return { ...snapshot, experimentalDesign: { specimens: [], plates: [], assignments: [], ...snapshot.experimentalDesign, [catalogue]: entries } } as ProjectSnapshot;
  return { ...snapshot, [catalogue]: entries };
}
export function adoptSnapshotCatalogues(snapshot: ProjectSnapshot): ProjectSnapshot {
  let result = snapshot;
  for (const pin of snapshot.selectedCatalogueEntries ?? []) if (pin.entry) result = mergeCatalogueEntry(result, pin.catalogue, pin.entry);
  // Activity is complete and bounded independently of recent history. Never let
  // an old selected worker replace its current active descriptor.
  for (const entry of snapshot.activeJobWorkers ?? []) result = mergeCatalogueEntry(result, "jobWorkers", entry as unknown as CatalogueEntry);
  for (const entry of snapshot.activeTrainingJobs ?? []) result = mergeCatalogueEntry(result, "trainingJobs", entry as unknown as CatalogueEntry);
  return result;
}
