/**
 * kernel/persistence/index.ts — the persistence singleton / provider.
 *
 * The one place the app resolves "which PersistencePort am I using". Pages +
 * the store call `getPort()` and never construct a concrete port themselves —
 * so the browser build swaps the factory here (desktop → `TauriSqlitePort`,
 * browser → `IndexedDbPort` / wa-sqlite) and nothing downstream changes.
 */

import type { PersistencePort } from "./PersistencePort";
import { TauriSqlitePort } from "./TauriSqlitePort";

export * from "./PersistencePort";
export { TauriSqlitePort } from "./TauriSqlitePort";

/** Lazily-constructed process-wide port instance. */
let instance: PersistencePort | null = null;

/** Factory for the active build's port. The browser build overrides this. */
function createDefaultPort(): PersistencePort {
  return new TauriSqlitePort();
}

/** The active `PersistencePort` (constructed on first use). */
export function getPort(): PersistencePort {
  if (instance === null) {
    instance = createDefaultPort();
  }
  return instance;
}

/**
 * Override the active port. Intended for the browser build's bootstrap and for
 * tests (inject a fake). Passing `null` resets to the default factory on the
 * next `getPort()` call.
 */
export function setPort(port: PersistencePort | null): void {
  instance = port;
}
