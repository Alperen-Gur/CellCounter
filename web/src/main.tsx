import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { registerSW } from "virtual:pwa-register";
import App from "./App";
import { announceUpdate } from "./app/appUpdate";

if (import.meta.env.PROD) {
  const update = registerSW({ immediate: true, onNeedRefresh() { announceUpdate(() => update(true)); } });
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
