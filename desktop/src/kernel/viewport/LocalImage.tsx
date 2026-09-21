import type { ComponentPropsWithRef } from "react";
import { useRecoverableImage } from "./useRecoverableImage";

/** Recover unsupported formats or missing thumbnails once; show a useful
 * failure instead of leaving a broken-image icon or retrying indefinitely. */
export function LocalImage({ src, onError, ...props }: ComponentPropsWithRef<"img">) {
  const preview = useRecoverableImage(src);
  if (preview.error) {
    return <span role="img" aria-label={props.alt || "Image preview unavailable"}
      title={preview.error} className={props.className} style={props.style}>
      Image preview unavailable
    </span>;
  }
  return <img {...props} src={preview.src} onError={event => {
    onError?.(event);
    preview.onError();
  }} />;
}
