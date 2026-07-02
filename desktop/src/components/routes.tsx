/**
 * components/routes.tsx — the shell's route + navigation registry.
 *
 * Single source of truth for "what screens exist and where they live". Each
 * entry lazy-imports a page from its own `pages/<name>/` directory. The Sidebar
 * renders from `NAV_SECTIONS` + `NAV_FOOTER`; `App.tsx` resolves the active
 * `RouteDef` by hash path. Routing is hash-based and dependency-free.
 *
 * Nav labels follow the product design (Queue / Images / Batches) even where the
 * underlying page directory keeps its feature-task id (review / library / batch).
 * Results, Processing and Onboarding are reachable routes but not rail items —
 * they open contextually (open an item, a run starts, first launch).
 */

import { lazy, type ComponentType, type LazyExoticComponent } from "react";
import type { IconName } from "./Icon";

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
  | "settings"
  | "finetune"
  | "trash"
  | "support";

export interface RouteDef {
  id: RouteId;
  path: string;
  label: string;
  icon: IconName;
  component: LazyExoticComponent<ComponentType>;
}

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
const ComingSoon = lazy(() => import("../pages/system/ComingSoon"));

export const ROUTES: RouteDef[] = [
  { id: "home", path: "/", label: "Home", icon: "home", component: HomePage },
  { id: "review", path: "/review", label: "Queue", icon: "queue", component: ReviewPage },
  { id: "library", path: "/library", label: "Images", icon: "image", component: LibraryPage },
  { id: "batch", path: "/batch", label: "Batches", icon: "batches", component: BatchPage },
  { id: "compare", path: "/compare", label: "Compare", icon: "compare", component: ComparePage },
  { id: "models", path: "/models", label: "Models", icon: "models", component: ModelsPage },
  { id: "finetune", path: "/finetune", label: "Fine-tune", icon: "finetune", component: ComingSoon },
  { id: "trash", path: "/trash", label: "Recently deleted", icon: "trash", component: ComingSoon },
  { id: "support", path: "/support", label: "Support", icon: "support", component: ComingSoon },
  { id: "settings", path: "/settings", label: "Settings", icon: "settings", component: SettingsPage },
  // Reachable but not rail items:
  { id: "processing", path: "/processing", label: "Processing", icon: "queue", component: ProcessingPage },
  { id: "results", path: "/results", label: "Results", icon: "results", component: ResultsPage },
  { id: "onboarding", path: "/onboarding", label: "Onboarding", icon: "calibrate", component: OnboardingPage },
];

export interface NavSection {
  title: string;
  routeIds: RouteId[];
}

/** Main grouped rail (top). */
export const NAV_SECTIONS: NavSection[] = [
  { title: "", routeIds: ["home", "review"] },
  { title: "Library", routeIds: ["library", "batch", "compare"] },
  { title: "System", routeIds: ["models", "finetune", "trash"] },
];

/** Bottom-pinned rail items. */
export const NAV_FOOTER: RouteId[] = ["support", "settings"];

export const DEFAULT_ROUTE: RouteDef = ROUTES[0];

export function routeForPath(rawHash: string): RouteDef {
  const path = normalizeHashPath(rawHash);
  return ROUTES.find((r) => r.path === path) ?? DEFAULT_ROUTE;
}

export function normalizeHashPath(rawHash: string): string {
  let h = rawHash.replace(/^#/, "").trim();
  if (h === "" || h === "/") return "/";
  if (!h.startsWith("/")) h = "/" + h;
  if (h.length > 1 && h.endsWith("/")) h = h.slice(0, -1);
  return h;
}
