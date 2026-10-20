import type { ImagePlane, MicroscopyWorkspace, WorkflowStep, WorkspaceLayer } from '../../../../shared/microscopy/types';
/** The same editor owns draft geometry and journals; the project host owns all durable execution and IO. */
export interface CanonicalWorkspaceAdapter {
  document: MicroscopyWorkspace;
  identity: string;
  blocked: boolean;
  saveBlocked: boolean;
  onDirty: (dirty: boolean) => void;
  resolvePlane: (layer: WorkspaceLayer, workspace: MicroscopyWorkspace) => Promise<ImagePlane>;
  save: (workspace: MicroscopyWorkspace) => Promise<void>;
  operation: (step: WorkflowStep) => Promise<void>;
  replay: (workflowId: string) => Promise<void>;
  renderExport: (kind: 'semantic' | 'animation', id: string) => Promise<void>;
  exportProject: () => Promise<void>;
  exportDraft: (workspace: MicroscopyWorkspace) => Promise<void>;
  linkPoints: (maxDistance: number) => Promise<void>;
  importGeometry: () => Promise<Partial<WorkspaceLayer> | undefined>;
}
