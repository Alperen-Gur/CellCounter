import { measureCells } from "../../../src/domain/measurements";
import type {
  AnalysisParameters,
  AnalysisProvenance,
  Calibration,
  DetectionResultDTO,
  ImageAnalysis,
  ModelProvenance,
} from "../../../src/domain/types";

export const calibration: Calibration = { pxPerUm: 2, source: "manual", confidence: "high" };

export const parameters: AnalysisParameters = {
  modelId: "cp-cyto3",
  confidenceThreshold: 0.5,
  expectedDiameterUm: 20,
  channels: [0, 0],
  backgroundSubtract: false,
  rollingBallRadiusPx: 50,
  watershedSplit: true,
  watershedMinDistanceUm: 8,
  sizeThresholdsUm: [2, 4],
};

export const model: ModelProvenance = {
  id: "cp-cyto3",
  displayName: "Cellpose cyto3",
  manifestVersion: "1.0.0",
  artifactSha256: "7b98ba5f2f0cf5b5d7532ef2ce1f3163a5b0c7cbf04a909d8c831a12a2f03e51",
  runtime: "onnxruntime-web/webgpu",
  runtimeVersion: "1.22.0",
};

export function sampleCells(offset = 0) {
  return measureCells(
    [
      {
        id: `cell-${offset + 1}`,
        centroidPx: { x: offset + 2, y: 2 },
        contourPx: [
          { x: offset, y: 0 },
          { x: offset + 4, y: 0 },
          { x: offset + 4, y: 4 },
          { x: offset, y: 4 },
        ],
        confidence: 0.9,
        origin: "model" as const,
      },
    ],
    calibration,
    { widthPx: 100, heightPx: 100 },
    parameters.sizeThresholdsUm,
  );
}

export function sampleAnalysis(id = "analysis-1", offset = 0): ImageAnalysis {
  return {
    schemaVersion: 1,
    id,
    image: {
      id: `image-${id}`,
      fileName: `${id}.png`,
      mediaType: "image/png",
      byteLength: 4,
      sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      widthPx: 100,
      heightPx: 100,
      importedAt: "2026-08-31T09:00:00.000Z",
    },
    calibration,
    parameters,
    model,
    ranAt: "2026-08-31T09:01:00.000Z",
    cells: sampleCells(offset),
    correctionLog: [],
    imageStats: {},
  };
}

export const provenance: AnalysisProvenance = {
  appVersion: "1.0.8",
  appBuild: "1",
  buildSha: "abcdef0",
  exportedAt: "2026-08-31T09:02:00.000Z",
  imageSha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  model,
  calibration,
  parameters,
};

export const emptyDetection: DetectionResultDTO = {
  imageWidth: 16,
  imageHeight: 16,
  cells: [],
  imageStats: {},
};
