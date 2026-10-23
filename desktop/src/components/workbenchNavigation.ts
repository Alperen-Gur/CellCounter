import { navigate } from "./useHashRoute";
import type { WorkbenchTaskId } from "../../../shared/workbench/navigation";

export type WorkbenchAction =
  | { kind: "task"; task: WorkbenchTaskId }
  | { kind: "import" }
  | { kind: "open-project" }
  | { kind: "new-project" }
  | { kind: "library-import" }
  | { kind: "agent-access" };

let pending: WorkbenchAction | undefined;
export const WORKBENCH_ACTION_EVENT = "cc:workbench-action";

/** Shell actions always reach the current project, including before its first mount. */
export function openWorkbench(action: WorkbenchAction = { kind: "task", task: "preparation" }): void {
  pending = action;
  navigate("workbench");
  window.dispatchEvent(new Event(WORKBENCH_ACTION_EVENT));
}

export function takeWorkbenchAction(): WorkbenchAction | undefined {
  const action = pending;
  pending = undefined;
  return action;
}
