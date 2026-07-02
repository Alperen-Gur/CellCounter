/**
 * pages/results/ResultsPage.tsx — STUB mount point for the Results screen.
 * Owned by feature task `feat-results-viewer`. This task owns pages/results/
 * EXCLUDING pages/results/editing/ (feat-mask-editing) and pages/results/segnpy/
 * (feat-seg-npy-io), which are separate, physically-disjoint mount points.
 */
import { StubPage } from "../../components/StubPage";

export default function ResultsPage() {
  return <StubPage name="Results" owner="feat-results-viewer" glyph="🔬" />;
}
