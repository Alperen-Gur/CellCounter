import { useEffect } from "react";
import WorkspacePage from "./WorkspacePage";

/** Desktop documents now belong to the shared project; browser demos retain
 * the same DOM-free editor and its explicitly limited local capabilities. */
export default function WorkspaceRoute() {
  const desktop = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
  useEffect(() => {
    if (desktop) window.location.hash = "/workbench";
  }, [desktop]);
  return desktop ? <p><a href="#/workbench">Open layer workspaces in Workbench</a></p> : <WorkspacePage />;
}
