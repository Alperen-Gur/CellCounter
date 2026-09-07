import { useEffect, useRef } from "react";

/** Keep keyboard focus in a modal and return it to the control that opened it. */
export function useDialogFocus(open: boolean) {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const host = ref.current;
    if (!open || !host) return;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const controls = () => Array.from(host.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), a[href], [tabindex="0"]'));
    (controls()[0] ?? host).focus();
    const trap = (event: KeyboardEvent) => {
      if (event.key !== "Tab") return;
      const items = controls();
      const first = items[0], last = items[items.length - 1];
      if (!first) { event.preventDefault(); host.focus(); return; }
      if (event.shiftKey && (document.activeElement === first || document.activeElement === host)) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    host.addEventListener("keydown", trap);
    return () => { host.removeEventListener("keydown", trap); if (previous?.isConnected) previous.focus(); };
  }, [open]);
  return ref;
}
