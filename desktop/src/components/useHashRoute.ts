/**
 * components/useHashRoute.ts — the shell's tiny hash router.
 *
 * A dependency-free replacement for a client-router package: it tracks
 * `window.location.hash`, resolves it to a `RouteDef`, and exposes a `navigate`
 * helper. Routing state lives here (and in the URL hash) rather than in the
 * FROZEN store, so no shell-only key leaks into a kernel slice.
 *
 * A page navigates with the exported `navigate(id)` — e.g. Home routes to
 * Results after dispatching detection — without importing any sibling page.
 */

import { useEffect, useState } from "react";
import { routeForPath, type RouteDef, type RouteId, ROUTES } from "./routes";

/** Imperatively navigate to a route by id (usable outside React too). */
export function navigate(id: RouteId): void {
  const route = ROUTES.find((r) => r.id === id);
  const path = route ? route.path : "/";
  const target = "#" + path;
  if (window.location.hash !== target) {
    window.location.hash = target;
  }
}

/** Subscribe to the current route; re-renders on hashchange. */
export function useHashRoute(): { route: RouteDef; navigate: (id: RouteId) => void } {
  const [route, setRoute] = useState<RouteDef>(() =>
    routeForPath(window.location.hash),
  );

  useEffect(() => {
    const onHashChange = () => setRoute(routeForPath(window.location.hash));
    window.addEventListener("hashchange", onHashChange);
    // Sync once in case the hash changed between initial render and mount.
    onHashChange();
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);

  return { route, navigate };
}
