import type { ReactNode } from "react";

import { WORKBENCH_TASKS, type WorkbenchTaskId } from "../../../../shared/workbench/navigation";
export { WORKBENCH_TASKS };
export type WorkbenchTask = WorkbenchTaskId;

export default function WorkbenchTaskNavigation({ selected, onSelect, pending }: {
  selected: WorkbenchTask; onSelect: (task: WorkbenchTask) => void; pending: Partial<Record<WorkbenchTask, string>>;
}) {
  return <nav className="workbench-task-navigation" aria-label="Workbench tasks">
    {WORKBENCH_TASKS.map((task) => <button key={task.id} type="button" className="cc-btn"
      aria-controls={`workbench-task-${task.id}`} aria-current={selected === task.id ? "page" : undefined}
      onClick={() => onSelect(task.id)}>
      <span>{task.label}</span>{pending[task.id] ? <small>{pending[task.id]}</small> : null}
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
      <h2 id={`workbench-task-heading-${task}`}>{definition.label}</h2>
      <p>{definition.description}</p>
    </header>
    {children}
  </section>;
}
