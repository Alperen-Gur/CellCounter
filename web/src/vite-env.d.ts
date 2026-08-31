/// <reference types="vite/client" />
/// <reference types="vite-plugin-pwa/client" />

interface Navigator {
  readonly gpu?: GPU;
  readonly storage: StorageManager & {
    getDirectory?: () => Promise<FileSystemDirectoryHandle>;
  };
}
