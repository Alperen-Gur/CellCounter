/** Holds a waiting update even when service-worker registration wins the startup race. */
let pendingUpdate: (() => Promise<void>) | undefined;
const listeners = new Set<() => void>();
export const getPendingUpdate = () => pendingUpdate;
export const subscribeUpdates = (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
export function announceUpdate(reload: () => Promise<void>) {
  pendingUpdate = reload;
  for (const listener of listeners) listener();
}
