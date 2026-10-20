import type { ReactNode } from "react";

export const WORKBENCH_TASKS = [
  { id: "preparation", name: "Images & preparation", description: "Import images, extract regions, align acquisitions and prepare retained working images." },
  { id: "segmentation", name: "Segmentation & correction", description: "Choose a segmentation method, inspect its result and correct saved object masks." },
  { id: "measurements", name: "Measurements", description: "Measure annotations, intensity profiles and biological assays for the selected image." },
  { id: "review", name: "Review", description: "Compare saved masks and record quality-control decisions." },
  { id: "workflows", name: "Workflows", description: "Organize experiments, configure reusable analyses and run batches or parameter sweeps." },
  { id: "export", name: "Results & export", description: "Summarize saved results and export scientific images, measurements or a complete analysis package." },
] as const;
export type WorkbenchTask = typeof WORKBENCH_TASKS[number]["id"];

export default function WorkbenchTaskNavigation({ selected, onSelect, pending }: {
  selected: WorkbenchTask; onSelect: (task: WorkbenchTask) => void; pending: Partial<Record<WorkbenchTask, string>>;
}) {
  return <nav className="workbench-task-navigation" aria-label="Workbench tasks">
    {WORKBENCH_TASKS.map((task) => <button key={task.id} type="button" className="cc-btn"
      aria-controls={`workbench-task-${task.id}`} aria-current={selected === task.id ? "page" : undefined}
      onClick={() => onSelect(task.id)}>
      <span>{task.name}</span>{pending[task.id] ? <small>{pending[task.id]}</small> : null}
    </button>)}
  </nav>;
}

export function WorkbenchTaskSection({ task, active, children }: {
  task: WorkbenchTask; active: WorkbenchTask; children: ReactNode;
}) {
  const definition = WORKBENCH_TASKS.find((item) => item.id === task)!;
  return <section id={`workbench-task-${task}`} className="workbench-task-section" hidden={active !== task}
    aria-labelledby={`workbench-task-heading-${task}`}>
    <header className="workbench-task-heading">
      <h2 id={`workbench-task-heading-${task}`}>{definition.name}</h2>
      <p>{definition.description}</p>
    </header>
    {children}
  </section>;
}
