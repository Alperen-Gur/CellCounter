/**
 * pages/results/segnpy/SegNpyPanel.tsx — STUB mount point for _seg.npy import/export.
 * Owned by feature task `feat-seg-npy-io`. SEPARATE directory from pages/results/
 * and pages/results/editing/ so the seg-npy round-trip UI owns disjoint files;
 * the Results page composes this panel. Fill pages/results/segnpy/ only.
 */
import { StubPage } from "../../../components/StubPage";

export default function SegNpyPanel() {
  return <StubPage name="Seg .npy I/O" owner="feat-seg-npy-io" glyph="🔁" />;
}
