import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { WorkspaceToolbar } from "../src/components/WorkspaceToolbar";
import { Inspector, type AnalysisSettings } from "../src/components/Inspector";
import { ProcessingPanel } from "../src/components/ProcessingPanel";
import { ShortcutDialog } from "../src/components/ShortcutDialog";
import { handleKeyboard, type KeyActions } from "../src/hooks/useKeyboard";
import { ReviewView } from "../src/views/ReviewView";
import { UpdateNotice } from "../src/components/UpdateNotice";
import { announceUpdate, getPendingUpdate, subscribeUpdates } from "../src/app/appUpdate";
import { Rail } from "../src/components/Rail";
import type { WorkspaceImage } from "../src/app/types";
import type { AnalysisJob } from "../src/app/workflow";
import { sampleAnalysis } from "./core/fixtures/sample";

afterEach(cleanup);
const settings: AnalysisSettings = { modelId: "classical", pxPerUm: 1, confidence: .5, diameterUm: 30, backgroundSubtract: false, watershedSplit: true };
const image = { id: "source", fileName: "sample.png", width: 320, height: 200, sourceLoaded: true, cells: [], pxPerUm: 1, groundTruth: [], rois: [], note: "", reviewConfidence: "high", calibrationSource: "default" } as unknown as WorkspaceImage;

describe("research workbench interaction contracts", () => {
  it("has one contextual execution action and keeps mismatched previews out of Process", () => {
    const run = vi.fn(), process = vi.fn();
    const props = { image, imageCount: 4, runState: "idle" as const, modelReady: true, onImport: vi.fn(), onRun: run, onProcess: process, onCancel: vi.fn(), onInspector: vi.fn(), scope: "image" as const, onScopeChange: vi.fn() };
    const view = render(<WorkspaceToolbar {...props} previewMatches={false} showingPreview={false} />);
    fireEvent.click(screen.getByRole("button", { name: "Preview image" })); expect(run).toHaveBeenCalledOnce();
    expect(screen.queryByRole("button", { name: "Process image" })).not.toBeInTheDocument();
    view.rerender(<WorkspaceToolbar {...props} previewCount={2} previewMatches showingPreview />);
    fireEvent.change(screen.getByLabelText("Processing scope"), { target: { value: "all" } });
    view.rerender(<WorkspaceToolbar {...props} scope="all" previewCount={2} previewMatches showingPreview />);
    fireEvent.click(screen.getByRole("button", { name: "Process all" })); expect(process).toHaveBeenCalledWith(true);
    view.rerender(<WorkspaceToolbar {...props} previewCount={2} previewMatches={false} showingPreview />);
    expect(screen.getByRole("button", { name: "Preview image" })).toBeInTheDocument();
    expect(screen.getByText(/settings changed/)).toBeInTheDocument();
  });
  it("keeps selection and source context separate without changing analysis settings", () => {
    const change = vi.fn();
    render(<Inspector image={image} selectedCell={{ id: "object-7", cx: 8, cy: 9, diameterPx: 10, diameterUm: 10, areaUm2: 70, confidence: 1 }} tool="inspect" onTool={vi.fn()} onMetadata={vi.fn()} onClearValidation={vi.fn()} settings={settings} onSettings={change} count={1} meanDiameter={10} onModelFile={vi.fn()} onExport={vi.fn()} modelReady mobileOpen={false} onClose={vi.fn()}><p>Recorded run fixture</p></Inspector>);
    expect(screen.getByLabelText("Segmentation model")).toBeInTheDocument();
    expect(screen.queryByText("object-7")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Selection" }));
    expect(screen.getByText("object-7")).toBeInTheDocument();
    expect(screen.queryByLabelText("Segmentation model")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^Image$/ }));
    expect(screen.getByText("Recorded run fixture")).toBeInTheDocument();
    expect(screen.getByText("Unverified default")).toBeInTheDocument();
    expect(change).not.toHaveBeenCalled();
  });
  it("shows partial failure and routes retry to the saved job without hiding completed work", () => {
    const analysis = sampleAnalysis();
    const job: AnalysisJob = { id: "j", createdAt: "2026-09-08T10:00:00Z", updatedAt: "2026-09-08T10:00:00Z", state: "failed", settings: { parameters: analysis.parameters, calibration: analysis.calibration, model: analysis.model }, items: [{ imageId: "a", fileName: "first.png", sourceSha256: "a", calibration: analysis.calibration, state: "complete", reusedPreview: true }, { imageId: "b", fileName: "second.png", sourceSha256: "b", calibration: analysis.calibration, state: "failed", error: "Cannot decode this image" }] };
    const resume = vi.fn();
    render(<ProcessingPanel image={image} images={[image]} busy={false} modelReady jobs={[job]} onProcess={vi.fn()} onResume={resume} onPause={vi.fn()} onCancel={vi.fn()} onReview={vi.fn()} onAnalyze={vi.fn()} />);
    expect(screen.getByText("1 of 2 completed · 1 need attention")).toBeInTheDocument();
    expect(screen.getByText("complete · preview reused")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry 1 failed" })); expect(resume).toHaveBeenCalledWith(job, true);
  });
  it("returns modal focus to the opening control", () => {
    const opener = document.createElement("button"); document.body.append(opener); opener.focus();
    const view = render(<ShortcutDialog open onClose={vi.fn()} />);
    expect(screen.getByRole("button", { name: "Close" })).toHaveFocus();
    fireEvent.keyDown(screen.getByRole("button", { name: "Close" }), { key: "Tab", shiftKey: true });
    expect(screen.getByRole("button", { name: "Close" })).toHaveFocus();
    view.unmount(); expect(opener).toHaveFocus(); opener.remove();
  });
  it("keeps capabilities out of primary navigation and retains labeled task routes", () => {
    const change = vi.fn(); render(<Rail active="workspace" onChange={change} collapsed={false} onCollapse={vi.fn()} />);
    expect(screen.queryByRole("button", { name: "Parity" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Processing" })); expect(change).toHaveBeenCalledWith("processing");
    expect(screen.getByRole("button", { name: "Collapse navigation" })).toBeInTheDocument();
  });
  it("wires modified import and task navigation while preserving AltGraph and text editing", () => {
    const actions: KeyActions = { route: "processing", importImages: vi.fn(), importFolder: vi.fn(), navigate: vi.fn(), run: vi.fn(), cancel: vi.fn(), exportResults: vi.fn(), setTool: vi.fn(), toggleTheme: vi.fn(), showHelp: vi.fn() };
    handleKeyboard(new KeyboardEvent("keydown", { key: "o", ctrlKey: true }), actions);
    expect(actions.importImages).toHaveBeenCalledOnce();
    handleKeyboard(new KeyboardEvent("keydown", { key: "O", metaKey: true, shiftKey: true }), actions);
    expect(actions.importFolder).toHaveBeenCalledOnce();
    handleKeyboard(new KeyboardEvent("keydown", { key: "4", ctrlKey: true, altKey: true }), actions);
    expect(actions.navigate).toHaveBeenCalledWith("review");
    const altGraph = new KeyboardEvent("keydown", { key: "1", ctrlKey: true, altKey: true });
    Object.defineProperty(altGraph, "getModifierState", { value: (key: string) => key === "AltGraph" });
    handleKeyboard(altGraph, actions); expect(actions.navigate).toHaveBeenCalledOnce();
    const input = document.createElement("input");
    const typing = new KeyboardEvent("keydown", { key: "o", ctrlKey: true }); Object.defineProperty(typing, "target", { value: input });
    handleKeyboard(typing, actions); expect(actions.importImages).toHaveBeenCalledOnce();
  });
  it("uses review shortcuts only on a focused object and respects modified keys", async () => {
    const accept = vi.fn();
    render(<ReviewView images={[{ ...image, reviewConfidence: "low", cells: [{ id: "c1", cx: 1, cy: 1, diameterPx: 10, diameterUm: 10, confidence: .2 }] }]} onOpen={vi.fn()} onAccept={accept} onReject={vi.fn()} onResize={vi.fn()} />);
    const row = screen.getByRole("listitem");
    await act(async () => { fireEvent.keyDown(row, { key: "k", ctrlKey: true }); }); expect(accept).not.toHaveBeenCalled();
    await act(async () => { fireEvent.keyDown(row, { key: "k" }); }); expect(accept).toHaveBeenCalledWith("source", "c1");
  });

  it("retains a waiting app update and reloads only after a safe explicit click", () => {
    const reload = vi.fn(async () => {});
    announceUpdate(reload);
    expect(getPendingUpdate()).toBe(reload);
    expect(reload).not.toHaveBeenCalled();
    const changed = vi.fn(), unsubscribe = subscribeUpdates(changed);
    announceUpdate(reload); expect(changed).toHaveBeenCalledOnce(); unsubscribe();
    const view = render(<UpdateNotice busy onReload={reload} />);
    fireEvent.click(screen.getByRole("button", { name: "Reload app" })); expect(reload).not.toHaveBeenCalled();
    view.rerender(<UpdateNotice busy={false} onReload={reload} />);
    fireEvent.click(screen.getByRole("button", { name: "Reload app" })); expect(reload).toHaveBeenCalledOnce();
  });

});
