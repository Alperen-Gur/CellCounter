/// <reference lib="webworker" />

import { WebGpuInference } from "../models/WebGpuInference";
import { BrowserRepository } from "../storage/BrowserRepository";
import { createInferenceWorkerController } from "./controller";
import type { InferenceWorkerRequest, InferenceWorkerResponse } from "./protocol";

const scope = self as unknown as DedicatedWorkerGlobalScope;
const engine = BrowserRepository.open().then((repository) => new WebGpuInference(repository.modelArtifactCache));
const controller = createInferenceWorkerController(engine, (response: InferenceWorkerResponse) => scope.postMessage(response));

scope.addEventListener("message", (event: MessageEvent<InferenceWorkerRequest>) => controller.handle(event.data));
scope.addEventListener("close", () => {
  controller.cancelAll();
  void engine.then((inference) => inference.dispose());
});
