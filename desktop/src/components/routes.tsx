/** Application routes retain existing-library links while Workbench is the default. */

import { lazy, type ComponentType, type LazyExoticComponent } from "react";
import type { IconName } from "./Icon";

export type RouteId =
  | "existing-library"
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
  | "workspace"
  | "workspace-archive"
  | "workbench"
  | "finetune"
  | "support";

export interface RouteDef {
  id: RouteId;
  path: string;
  label: string;
  icon: IconName;
  component: LazyExoticComponent<ComponentType>;
}

const ExistingLibrary = lazy(() => import("./ExistingLibrary"));
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
const SupportPage = lazy(() => import("../pages/system/SupportPage"));
const WorkspacePage=lazy(()=>import("../pages/workspace/WorkspaceRoute"));
const WorkspaceArchivePage = lazy(() => import("../pages/workspace/WorkspaceArchivePage"));
const WorkbenchPage = lazy(() => import("../pages/workbench/WorkbenchPage"));
const FineTunePage = lazy(() => import("../pages/finetune/FineTunePage"));

export const ROUTES: RouteDef[] = [
  { id: "existing-library", path: "/existing-library", label: "Existing library", icon: "image", component: ExistingLibrary },
  { id: "home", path: "/legacy/import", label: "Add to existing library", icon: "home", component: HomePage },
  { id: "review", path: "/review", label: "Existing review queue", icon: "queue", component: ReviewPage },
  { id: "library", path: "/library", label: "Existing images", icon: "image", component: LibraryPage },
  { id: "batch", path: "/batch", label: "Existing batches", icon: "batches", component: BatchPage },
  { id: "compare", path: "/compare", label: "Existing comparisons", icon: "compare", component: ComparePage },
  { id: "workspace",path:"/workspace",label:"Layer workspace",icon:"layers",component:WorkspacePage },
  { id: "workspace-archive", path: "/workspace-archive", label: "Original workspace archive", icon: "layers", component: WorkspaceArchivePage },
  { id: "workbench", path: "/workbench", label: "Workbench", icon: "scope", component: WorkbenchPage },
  { id: "models", path: "/models", label: "Existing model environments", icon: "models", component: ModelsPage },
  { id: "finetune", path: "/finetune", label: "Existing fine-tuning", icon: "finetune", component: FineTunePage },
  { id: "support", path: "/support", label: "Support", icon: "support", component: SupportPage },
  { id: "settings", path: "/settings", label: "Settings", icon: "settings", component: SettingsPage },
  // Reachable but not rail items:
  { id: "processing", path: "/processing", label: "Existing runs", icon: "queue", component: ProcessingPage },
  { id: "results", path: "/results", label: "Existing result", icon: "results", component: ResultsPage },
  { id: "onboarding", path: "/onboarding", label: "Existing library calibration", icon: "calibrate", component: OnboardingPage },
];

export interface NavSection {
  title: string;
  routeIds: RouteId[];
}

/** Main grouped rail (top). */
export const NAV_SECTIONS: NavSection[] = [
  { title: "", routeIds: ["workbench", "existing-library"] },
];

/** Bottom-pinned rail items. */
export const NAV_FOOTER: RouteId[] = ["support", "settings"];

export const WORKBENCH_ROUTE = ROUTES.find(route => route.id === "workbench")!;
export const DEFAULT_ROUTE: RouteDef = WORKBENCH_ROUTE;

const LIBRARY_ROUTES: RouteId[] = ["home", "processing", "results", "library", "batch", "compare", "review", "models", "finetune", "onboarding", "workspace", "workspace-archive"];
export function isExistingLibraryRoute(id: RouteId): boolean {
  return id === "existing-library" || LIBRARY_ROUTES.includes(id);
}

export function routeForPath(rawHash: string): RouteDef {
  const path = normalizeHashPath(rawHash);
  if (path === "/") return DEFAULT_ROUTE;
  return ROUTES.find((r) => r.path === path) ?? DEFAULT_ROUTE;
}

export function normalizeHashPath(rawHash: string): string {
  let h = rawHash.replace(/^#/, "").trim();
  if (h === "" || h === "/") return "/";
  if (!h.startsWith("/")) h = "/" + h;
  if (h.length > 1 && h.endsWith("/")) h = h.slice(0, -1);
  return h;
}
