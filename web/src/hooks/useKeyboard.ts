import { useEffect } from "react";

export interface KeyActions {
  importImages: () => void;
  run: () => void;
  cancel: () => void;
  exportResults: () => void;
  setTool: (index: number) => void;
  toggleTheme: () => void;
  showHelp: () => void;
}

export function useKeyboard(actions: KeyActions): void {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target?.matches("input, textarea, select, [contenteditable='true']")) return;
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        actions.run();
      } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "e") {
        event.preventDefault();
        actions.exportResults();
      } else if (event.key.toLowerCase() === "i") actions.importImages();
      else if (event.key === "Escape") actions.cancel();
      else if (/^[1-6]$/.test(event.key)) actions.setTool(Number(event.key) - 1);
      else if (event.key.toLowerCase() === "t") actions.toggleTheme();
      else if (event.key === "?") actions.showHelp();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [actions]);
}
