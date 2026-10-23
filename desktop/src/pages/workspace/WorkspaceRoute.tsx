import WorkspacePage from "./WorkspacePage";
import WorkspaceArchivePage from "./WorkspaceArchivePage";

/** Desktop documents now belong to the shared project; browser demos retain
 * the same DOM-free editor and its explicitly limited local capabilities. */
export default function WorkspaceRoute() {
  const desktop = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
  return desktop ? <WorkspaceArchivePage /> : <WorkspacePage />;
}
