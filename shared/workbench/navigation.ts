/** Task navigation is shared by graphical hosts and canonical operation discovery. */
export const WORKBENCH_TASKS = [
  { "id": "preparation", "label": "Images", "description": "Import, organize and prepare images and sources." },
  { "id": "segmentation", "label": "Segmentation", "description": "Segment objects and correct exact labels with classical or learned methods." },
  { "id": "measurements", "label": "Measurements", "description": "Measure objects and assays, track lineages and compare experimental results." },
  { "id": "review", "label": "Review", "description": "Inspect disagreements and record review decisions." },
  { "id": "workflows", "label": "Workflows", "description": "Organize experiments, reusable workflows and resumable jobs." },
  { "id": "export", "label": "Results & export", "description": "Inspect summaries and export images, tables and portable analysis packages." }
] as const;

export type WorkbenchTask = typeof WORKBENCH_TASKS[number];
export type WorkbenchTaskId = WorkbenchTask["id"];

export interface NavigationOperation {
  name: string;
  description: string;
  navigationTask?: WorkbenchTaskId;
  mutating: boolean;
  requiresProject: boolean;
  requiresExpectedRevision?: boolean;
  affectsProjectRevision?: boolean;
  usesExecutableCode?: boolean;
  installsExecutableCode?: boolean;
  usesNetwork?: boolean;
  networkProfileArgument?: string;
  hostLocalConfiguration?: boolean;
  configurationKind?: string;
  access?: { permission: "granted" | "conditional" | "restricted"; requiredGrants: string[];
    conditions: string[]; runtimeAvailability: "not-probed" };
}

export interface NavigationCatalog {
  schemaVersion: 1;
  defaultTask: WorkbenchTaskId;
  tasks: { id: WorkbenchTaskId; label: string; description: string; operationNames: string[] }[];
  operations: NavigationOperation[];
  unassignedOperationNames: string[];
  notes: string[];
}

export function isWorkbenchTaskId(value: unknown): value is WorkbenchTaskId {
  return typeof value === "string" && WORKBENCH_TASKS.some(task => task.id === value);
}

/** Resolve only explicit canonical assignments; a new/unknown operation has no guessed destination. */
export function taskForOperation(operation: string, catalog: NavigationCatalog): WorkbenchTaskId | null {
  const task = catalog.operations.find(entry => entry.name === operation)?.navigationTask;
  return isWorkbenchTaskId(task) ? task : null;
}
