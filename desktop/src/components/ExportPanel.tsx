/**
 * components/ExportPanel.tsx — STUB.
 *
 * Owned by feature task `feat-export`. It will surface the export actions
 * (annotated PNG, cells.csv, summary.csv, annotations.csv, provenance.json, PDF
 * report, ImageJ RoiSet.zip) that call the Rust export commands. Stubbed here so
 * pages that mount an export entry point compile today. Imports nothing from
 * sibling pages.
 */
import { StubPage } from "./StubPage";

export function ExportPanel() {
  return <StubPage name="Export" owner="feat-export" glyph="📤" />;
}

export default ExportPanel;
