import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: "prompt",
      includeAssets: ["favicon.svg"],
      manifest: {
        name: "CellCounter Web",
        short_name: "CellCounter",
        description: "Private, browser-native cell segmentation and measurement.",
        theme_color: "#f4f3ee",
        background_color: "#f4f3ee",
        display: "standalone",
        start_url: "/",
        scope: "/",
        categories: ["medical", "productivity", "utilities"],
        icons: [
          {
            src: "/favicon.svg",
            sizes: "any",
            type: "image/svg+xml",
            purpose: "any maskable"
          }
        ]
      },
      workbox: {
        globPatterns: ["**/*.{js,css,html,svg,woff2}"],
        // Inference is an explicit, model-gated action. Keep ORT and the inference
        // worker out of install-time downloads and cache them only after first use.
        globIgnores: ["**/ort*", "**/inference.worker-*", "models/**"],
        maximumFileSizeToCacheInBytes: 2 * 1024 * 1024,
        navigateFallback: "/index.html",
        // ORT uses the browser's ordinary same-origin HTTP cache on demand;
        // the service worker intentionally has no general runtime network cache.
        runtimeCaching: []
      }
    })
  ],
  build: {
    target: "es2022",
    sourcemap: false,
    chunkSizeWarningLimit: 1500
  },
  worker: { format: "es" }
});
