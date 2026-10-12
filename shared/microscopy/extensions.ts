import { fail } from './guards';
export type ExtensionCapability = 'readCommonImages' | 'readVendorImages' | 'readOMEZarr' | 'detectCellpose' | 'detectStarDist' | 'classicalSegmentation' | 'measureMorphology' | 'measureIntensity' | 'measureSpatial' | 'exportTables' | 'exportROIs' | 'exportAnimation';
export interface WorkspaceExtensionDescriptor { id: string; name: string; version: string; kind: 'reader' | 'detector' | 'assay' | 'measurement' | 'exporter'; summary: string; capabilities: ExtensionCapability[]; minimumWorkspaceSchema: 1; publisher: 'CellCounter Project'; isBundled: true }
const descriptors: WorkspaceExtensionDescriptor[] = [
  { id: 'org.cellcounter.reader.common', name: 'Common images', kind: 'reader', summary: 'Local images supported by this host reader.', capabilities: ['readCommonImages'] },
  { id: 'org.cellcounter.reader.vendor', name: 'Microscope containers', kind: 'reader', summary: 'Local microscope containers supported by this host reader.', capabilities: ['readVendorImages'] },
  { id: 'org.cellcounter.reader.omezarr', name: 'OME-Zarr / NGFF', kind: 'reader', summary: 'Local v2 arrays, pyramids and plate fields; uncompressed, zlib and gzip chunks.', capabilities: ['readOMEZarr'] },
  { id: 'org.cellcounter.detector.cellpose', name: 'Cellpose', kind: 'detector', summary: 'The Cellpose checkpoints installed and available on this host.', capabilities: ['detectCellpose'] },
  { id: 'org.cellcounter.detector.stardist', name: 'StarDist', kind: 'detector', summary: 'The StarDist checkpoints installed and available on this host.', capabilities: ['detectStarDist'] },
  { id: 'org.cellcounter.detector.classical', name: 'Classical segmentation', kind: 'detector', summary: 'Local threshold and watershed segmentation.', capabilities: ['classicalSegmentation'] },
  { id: 'org.cellcounter.measurement.morphology', name: 'Morphology and spatial measurements', kind: 'measurement', summary: 'Measurements exposed by the host analysis workflow.', capabilities: ['measureMorphology', 'measureSpatial'] },
  { id: 'org.cellcounter.assay.intensity', name: 'Intensity measurements', kind: 'assay', summary: 'Intensity assays exposed by the host analysis workflow.', capabilities: ['measureIntensity'] },
  { id: 'org.cellcounter.export.tables', name: 'Tables and regions', kind: 'exporter', summary: 'The table and ROI formats provided by the host exporter.', capabilities: ['exportTables', 'exportROIs'] },
  { id: 'org.cellcounter.export.animation', name: 'Workspace animation', kind: 'exporter', summary: 'Local GIF89a presentation export using a fixed palette.', capabilities: ['exportAnimation'] },
].map(descriptor => ({ ...descriptor, version: '1.0', minimumWorkspaceSchema: 1, publisher: 'CellCounter Project', isBundled: true })) as WorkspaceExtensionDescriptor[];
/** Capability discovery only. The host must pass only capabilities wired and
 * currently available; no third-party descriptor/script execution is provided. */
export function bundledExtensions(implemented: readonly ExtensionCapability[]): WorkspaceExtensionDescriptor[] { const available = new Set(implemented); return descriptors.map(descriptor => ({ ...descriptor, capabilities: descriptor.capabilities.filter(capability => available.has(capability)) })).filter(descriptor => descriptor.capabilities.length > 0).sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name)); }
export function installExecutableExtension(): never { return fail('executable-extension-unavailable', 'Executable third-party workspace plugins are unsupported.'); }
