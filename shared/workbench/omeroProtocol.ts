export interface OmeroProfile {
  id: string; name: string; host: string; port: number; username: string;
  credentialKind: "environment" | "local-file"; certificateAuthority: "custom-ca" | "platform-ca"; secure: true;
}
export interface OmeroRuntime {
  configured: boolean; registryPath?: string; configurationHash: string;
  pythonPath?: string; pythonSha256?: string; interpreterPresent?: boolean;
  status: string; requiredOmeroVersion: string; profiles: OmeroProfile[]; notes: string[];
}
export interface OmeroConnection {
  profileId: string; server: { host: string; port: number; transport: "tls"; certificateValidation: string; caSha256: string | null };
  user: { id: number; username: string }; groupId: number;
}
export interface OmeroImage {
  id: number; name: string; pixelsId: number; groupId: number;
  dimensions: { x: number; y: number; z: number; c: number; t: number };
  axes: "TCZYX"; shape: number[]; dtype: string;
  voxelSizeUm: { x: number | null; y: number | null; z: number | null };
  physicalSize: Record<string, { value: number; unit: string } | null>;
  timeStepSeconds: number | null; notes: string[];
}
export type OmeroObjectKind = "project" | "dataset" | "image" | "screen" | "plate" | "well";
export interface OmeroObject { id: number; name: string; kind: OmeroObjectKind; groupId: number; row?: number; column?: number }
export interface OmeroRegion {
  timeIndex: number; channel: number; zIndex: number; x: number; y: number; width: number; height: number;
}
export interface OmeroPreview {
  image: OmeroImage; connection: OmeroConnection; selection: OmeroRegion; pixelSha256: string;
  dataUrl: string; width: number; height: number; previewFingerprint: string; notes: string[];
}
export interface OmeroActions {
  run: (action: () => Promise<void>) => Promise<void>;
  chooseFile: (title: string, accepted: (path: string) => Promise<void> | void) => Promise<void>;
  importRegion: (args: Record<string, unknown>) => Promise<void>;
}
