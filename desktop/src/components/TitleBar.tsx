/**
 * components/TitleBar.tsx — custom Windows-native title bar.
 *
 * With `decorations: false` the OS chrome is off and we draw our own bar: an
 * app mark + name on the left (draggable via `data-tauri-drag-region`) and
 * Fluent-style minimize / maximize / close controls on the right, wired to the
 * Tauri window API. Outside Tauri (browser preview) the controls hide and the
 * bar is purely visual, so the same shell renders in a normal browser.
 */

import { useEffect, useState } from "react";
import { Icon } from "./Icon";

function isTauri(): boolean {
  return (
    typeof window !== "undefined" &&
    ("__TAURI_INTERNALS__" in window || "__TAURI__" in window)
  );
}

export function TitleBar() {
  const [tauri, setTauri] = useState(false);
  const [maximized, setMaximized] = useState(false);

  useEffect(() => {
    setTauri(isTauri());
  }, []);

  const win = async () => {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    return getCurrentWindow();
  };

  // Track the maximized state so the control shows the correct glyph/label
  // ("Maximize" square vs "Restore" overlapping squares), like native Windows
  // chrome. We read the initial state on mount and keep it live via `onResized`
  // (fires on maximize/unmaximize/snap/drag-resize). Skipped outside Tauri.
  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void (async () => {
      try {
        const w = await win();
        const sync = async () => {
          try {
            const m = await w.isMaximized();
            if (!cancelled) setMaximized(m);
          } catch {
            /* ignore transient window API errors */
          }
        };
        await sync();
        const stop = await w.onResized(() => {
          void sync();
        });
        if (cancelled) {
          stop();
        } else {
          unlisten = stop;
        }
      } catch {
        /* window API unavailable — leave the default (unmaximized) glyph */
      }
    })();
    return () => {
      cancelled = true;
      if (unlisten) unlisten();
    };
  }, []);

  const minimize = () => {
    void win().then((w) => w.minimize()).catch(() => {});
  };
  const toggleMaximize = () => {
    void win().then((w) => w.toggleMaximize()).catch(() => {});
  };
  const close = () => {
    void win().then((w) => w.close()).catch(() => {});
  };

  return (
    <header className="cc-titlebar" data-tauri-drag-region>
      <div className="cc-titlebar__brand" data-tauri-drag-region>
        <span className="cc-titlebar__mark" aria-hidden="true">
          <Icon name="scope" size={17} strokeWidth={1.9} />
        </span>
        <span className="cc-titlebar__name">CellCounter</span>
      </div>

      <div className="cc-titlebar__spacer" data-tauri-drag-region />

      {tauri && (
        <div className="cc-winctl">
          <button
            type="button"
            className="cc-winctl__btn"
            onClick={minimize}
            aria-label="Minimize"
            title="Minimize"
          >
            <Icon name="windowMin" size={15} strokeWidth={1.6} />
          </button>
          <button
            type="button"
            className="cc-winctl__btn"
            onClick={toggleMaximize}
            aria-label={maximized ? "Restore" : "Maximize"}
            title={maximized ? "Restore" : "Maximize"}
          >
            <Icon
              name={maximized ? "windowRestore" : "windowMax"}
              size={13}
              strokeWidth={1.6}
            />
          </button>
          <button
            type="button"
            className="cc-winctl__btn cc-winctl__btn--close"
            onClick={close}
            aria-label="Close"
            title="Close"
          >
            <Icon name="windowClose" size={15} strokeWidth={1.6} />
          </button>
        </div>
      )}
    </header>
  );
}

export default TitleBar;
