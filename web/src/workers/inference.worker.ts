/// <reference lib="webworker" />

import { ClassicalInference } from "../models/ClassicalInference";
import { WebGpuInference } from "../models/WebGpuInference";
import { BrowserRepository } from "../storage/BrowserRepository";
import { createInferenceWorkerController } from "./controller";
import type { InferenceWorkerRequest, InferenceWorkerResponse } from "./protocol";

const scope = self as unknown as DedicatedWorkerGlobalScope;
const engine = BrowserRepository.open().then((repository) => ({ learned: new WebGpuInference(repository.modelArtifactCache), classical: new ClassicalInference() }));
const controller = createInferenceWorkerController(engine.then(({ learned, classical }) => ({ analyze: (request) => request.parameters.modelId === "classical" ? classical.analyze(request) : learned.analyze(request) })), (response: InferenceWorkerResponse) => scope.postMessage(response));

scope.addEventListener("message", (event: MessageEvent<InferenceWorkerRequest>) => controller.handle(event.data));
scope.addEventListener("close", () => {
  controller.cancelAll();
  void engine.then((inference) => inference.learned.dispose());
});
