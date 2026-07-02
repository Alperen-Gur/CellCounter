/**
 * App.tsx — the CellCounter application shell.
 *
 * Composes the persistent chrome (Sidebar + top bar) around a hash-routed
 * content pane that renders exactly one feature page. Routing is driven by the
 * dependency-free `useHashRoute` hook + the `ROUTES` registry, so:
 *   - no client-router package is added, and
 *   - route state lives in the URL hash, never in the FROZEN kernel store.
 *
 * On mount it runs launch-time app-data init (persistence + env probe) via
 * `initAppData`. Each page is lazy-loaded from its own directory behind a
 * <Suspense> boundary, keeping the 14 feature directories physically disjoint.
 *
 * This file is shell-owned. Feature engineers fill their `pages/<name>/`
 * directory and never edit App.tsx, the router, the Sidebar, or the theme.
 */

import { Suspense, useEffect, useState } from "react";

import { Sidebar } from "./components/Sidebar";
import { KeyboardShortcutsSheet } from "./components/KeyboardShortcutsSheet";
import { useHashRoute } from "./components/useHashRoute";
import { initAppData } from "./components/appInit";

import "./styles/theme.css";
import "./styles/shell.css";

function App() {
  const { route, navigate } = useHashRoute();
  const [shortcutsOpen, setShortcutsOpen] = useState(false);

  // Launch-time app-data init: persistence read + env availability probe.
  // Guarded internally against StrictMode's double-invoke.
  useEffect(() => {
    void initAppData();
  }, []);

  // Global "?" opens the (stubbed) shortcuts sheet — a shell affordance the
  // keyboard feature later replaces with the real per-scope keymap.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing =
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable);
      if (!typing && e.key === "?") {
        e.preventDefault();
        setShortcutsOpen((v) => !v);
      }
      if (e.key === "Escape") setShortcutsOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const PageComponent = route.component;

  return (
    <div className="cc-app">
      <Sidebar activeId={route.id} onNavigate={navigate} />

      <div className="cc-main">
        <header className="cc-topbar">
          <span className="cc-topbar__title">{route.label}</span>
          <span className="cc-topbar__spacer" />
          <span className="cc-topbar__hint">Press ? for shortcuts</span>
        </header>

        <main className="cc-content">
          <Suspense fallback={<div className="cc-loading">Loading…</div>}>
            <PageComponent />
          </Suspense>
        </main>
      </div>

      <KeyboardShortcutsSheet
        open={shortcutsOpen}
        onClose={() => setShortcutsOpen(false)}
      />
    </div>
  );
}

export default App;
