export interface LibraryImageMetadata {
  id: string; name: string; notes: string; tags: string[]; channelNames: string[]; archived: boolean;
  metadataRevision: number; sourceHash: string; width: number; height: number; channels: number;
}
export interface ImageCollection { id: string; name: string; description: string; imageIds: string[]; archived: boolean; updatedAt: string; updatedRevision?: number }
export interface LibrarySearch { images: LibraryImageMetadata[]; total: number; offset: number; nextOffset: number | null; archiveScope: "active" | "all" | "archived" }
export interface LibraryDuplicates { groups: { sourceHash: string; imageIds: string[]; names: string[]; bytes: number }[]; notes: string[] }
export interface SourceRepairPreview { imageId: string; sourceHash: string; candidateHash: string; identityMatches: boolean; currentArtifactStatus: "intact" | "missing" | "corrupt"; displacedHash?: string; bytes: number; previewFingerprint: string; notes: string[] }
export type LibraryMutation = "image.metadata.set" | "collection.save" | "collection.archive" | "image.archive" | "image.relink.run";
export interface LibraryActions {
  run: (action: () => Promise<void>) => Promise<void>;
  mutate: <T>(operation: LibraryMutation, args: Record<string, unknown>, expectedRevision: number, accepted?: (result: T) => void) => Promise<void>;
  chooseSource: (accepted: (path: string) => void) => Promise<void>;
  selectImage: (imageId: string) => Promise<void>;
}
