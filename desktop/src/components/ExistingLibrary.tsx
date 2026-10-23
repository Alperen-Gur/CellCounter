import { navigate } from "./useHashRoute";
import { openWorkbench } from "./workbenchNavigation";
import { useAppStore } from "../kernel/store/store";

/** Original records keep their own identifiers until an explicit project import. */
export default function ExistingLibrary() {
  const images = useAppStore(state => state.libraryImageCount);
  const batches = useAppStore(state => state.libraryBatchCount);
  const queued = useAppStore(state => state.reviewQueueCount);
  return <section className="cc-existing-library" aria-labelledby="existing-library-title">
    <header><h1 id="existing-library-title">Existing library</h1>
      <p>Open earlier images and runs, or copy them into a Workbench project. Original files, saved results and history stay in place.</p></header>
    <div className="cc-existing-library__summary"><span>{images} images</span><span>{batches} batches</span><span>{queued} review items</span></div>
    <div className="cc-existing-library__actions">
      <button type="button" className="cc-btn cc-btn--primary" onClick={() => openWorkbench({ kind: "library-import" })}>Import into Workbench…</button>
      <button type="button" className="cc-btn" onClick={() => navigate("library")}>Browse existing images</button>
      <button type="button" className="cc-btn" onClick={() => navigate("processing")}>Open existing runs</button>
      <button type="button" className="cc-btn" onClick={() => navigate("workspace-archive")}>Open original layer workspace</button>
    </div>
    <p>New analysis belongs in Workbench, where the graphical interface, command line and MCP share the same project operations.</p>
    <details><summary>Other existing-library tools</summary>
      <div className="cc-existing-library__actions">
        <button type="button" className="cc-btn" onClick={() => navigate("review")}>Existing review queue</button>
        <button type="button" className="cc-btn" onClick={() => navigate("batch")}>Existing batches</button>
        <button type="button" className="cc-btn" onClick={() => navigate("compare")}>Existing comparisons</button>
        <button type="button" className="cc-btn" onClick={() => navigate("home")}>Add to existing library…</button>
        <button type="button" className="cc-btn" onClick={() => navigate("models")}>Existing model environments</button>
        <button type="button" className="cc-btn" onClick={() => navigate("finetune")}>Existing fine-tuning</button>
      </div>
    </details>
  </section>;
}
