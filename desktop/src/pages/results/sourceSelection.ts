import { useEffect, useState } from "react";
import { invoke, convertFileSrc } from "@tauri-apps/api/core";
export interface SourcePreview { path: string; width: number; height: number; previewWidth: number; previewHeight: number; stride: number; channelCount: number; channelNames: string[]; values?: number[]; min: number; max: number; tCount:number; zCount:number; pxPerUm:number; sourceHash?:string; imageId:string }
export function useSourcePreview(imageId: string | undefined, channel: number | null | undefined, projection = "max", timeIndex=0, zIndex:number|null=null) {
  const [result, setResult] = useState<{key:string;preview?:SourcePreview;error?:string}>();
  const key = `${imageId}:${channel ?? "auto"}:${projection}:${timeIndex}:${zIndex ?? "project"}`;
  useEffect(() => {
    if (!imageId) return;
    let alive=true;let path:string|undefined;
    const runId=crypto.randomUUID();
    void invoke<SourcePreview>("parity_source",{imageId,operation:"source",request:{channel:channel ?? null,projection,timeIndex,zIndex},runId}).then(preview=>{
      path=preview.path;
      if(alive)setResult({key,preview});else void invoke("release_source_preview",{path});
    }).catch(error=>{if(alive)setResult({key,error:String(error)});});
    return()=>{alive=false;void invoke("cancel_assay",{runId});if(path)void invoke("release_source_preview",{path});};
  },[imageId,channel,projection,timeIndex,zIndex,key]);
  const current=result?.key===key ? result : undefined;
  return {preview:current?.preview,src:current?.preview ? convertFileSrc(current.preview.path) : null,error:current?.error,loading:!!imageId && !current};
}
