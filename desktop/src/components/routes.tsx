/**
 * components/routes.tsx — the shell's route + navigation registry.
 *
 * Single source of truth for "what screens exist and where they live". Each
 * entry lazy-imports a page from its own `pages/<name>/` directory, so pages
 * stay physically disjoint (a feature engineer fills exactly one directory and
 * never touches this file's siblings). The Sidebar renders from `NAV_SECTIONS`;
 * the router in `App.tsx` resolves the active `RouteDef` by hash path.
 *
 * Routing is hash-based (`#/results`) and dependency-free on purpose — no
 * client-router package is pulled in, and route state lives here rather than in
 * the FROZEN zustand store (whose slice shapes must not grow shell-only keys).
 *
 * Feature ownership (docs/tasks.json) — each page dir is owned by one task:
 *   home→feat-home-import · processing→feat-processing · results→feat-results-viewer
 *   results/editing→feat-mask-editing · results/segnpy→feat-seg-npy-io
 *   batch→feat-batch · compare→feat-compare · models→feat-models
 *   library→feat-library-dedup · review→feat-review-queue
 *   onboarding→feat-calibration-onboarding · settings→feat-settings
 */

import { lazy, type ComponentType, type LazyExoticComponent } from "react";

/** Stable identifier for a screen; also its hash path segment. */
export type RouteId =
  | "home"
  | "processing"
  | "results"
  | "batch"
  | "compare"
  | "models"
  | "library"
  | "review"
  | "onboarding"
  | "settings";

export interface RouteDef {
  id: RouteId;
  /** Hash path, e.g. "/results". */
  path: string;
  /** Sidebar label. */
  label: string;
  /** One-emoji glyph used as a lightweight sidebar icon (no icon dep yet). */
  icon: string;
  /** Lazy page component owned by the feature that fills `pages/<id>/`. */
  component: LazyExoticComponent<ComponentType>;
}

// Lazy imports keep each page in its own chunk AND its own file tree, so
// features never share a module with a sibling page.
const HomePage = lazy(() => import("../pages/home/HomePage"));
const ProcessingPage = lazy(() => import("../pages/processing/ProcessingPage"));
const ResultsPage = lazy(() => import("../pages/results/ResultsPage"));
const BatchPage = lazy(() => import("../pages/batch/BatchPage"));
const ComparePage = lazy(() => import("../pages/compare/ComparePage"));
const ModelsPage = lazy(() => import("../pages/models/ModelsPage"));
const LibraryPage = lazy(() => import("../pages/library/LibraryPage"));
const ReviewPage = lazy(() => import("../pages/review/ReviewPage"));
const OnboardingPage = lazy(() => import("../pages/onboarding/OnboardingPage"));
const SettingsPage = lazy(() => import("../pages/settings/SettingsPage"));

export const ROUTES: RouteDef[] = [
  { id: "home", path: "/", label: "Home", icon: "🏠", component: HomePage },
  { id: "processing", path: "/processing", label: "Processing", icon: "⏳", component: ProcessingPage },
  { id: "results", path: "/results", label: "Results", icon: "🔬", component: ResultsPage },
  { id: "batch", path: "/batch", label: "Batch", icon: "🗂️", component: BatchPage },
  { id: "compare", path: "/compare", label: "Compare", icon: "📊", component: ComparePage },
  { id: "library", path: "/library", label: "Library", icon: "🖼️", component: LibraryPage },
  { id: "review", path: "/review", label: "Review", icon: "✅", component: ReviewPage },
  { id: "models", path: "/models", label: "Models", icon: "🧠", component: ModelsPage },
  { id: "onboarding", path: "/onboarding", label: "Onboarding", icon: "🚀", component: OnboardingPage },
  { id: "settings", path: "/settings", label: "Settings", icon: "⚙️", component: SettingsPage },
];

/** Grouped nav layout mirroring the Swift `Sidebar.swift` sections. */
export interface NavSection {
  title: string;
  routeIds: RouteId[];
}

export const NAV_SECTIONS: NavSection[] = [
  { title: "Workflow", routeIds: ["home", "processing", "results", "review"] },
  { title: "Library", routeIds: ["library", "batch", "compare"] },
  { title: "System", routeIds: ["models", "onboarding", "settings"] },
];

/** The route shown when the hash is empty or unrecognised. */
export const DEFAULT_ROUTE: RouteDef = ROUTES[0];

/** Resolve a hash path (with or without a leading "#") to a RouteDef. */
export function routeForPath(rawHash: string): RouteDef {
  const path = normalizeHashPath(rawHash);
  return ROUTES.find((r) => r.path === path) ?? DEFAULT_ROUTE;
}

/** Normalise "#/results", "/results", "results", "" → a leading-slash path. */
export function normalizeHashPath(rawHash: string): string {
  let h = rawHash.replace(/^#/, "").trim();
  if (h === "" || h === "/") return "/";
  if (!h.startsWith("/")) h = "/" + h;
  // strip any trailing slash except the root
  if (h.length > 1 && h.endsWith("/")) h = h.slice(0, -1);
  return h;
}
