import WorkbenchImageSelector, { useWorkbenchImage } from "./WorkbenchImageSelector";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { ParameterSpec, ParameterValue } from "../../../../shared/workbench/extensionProtocol";
import PluginParameters from "./PluginParameters";

export default function AssayParameters({ schema, values, onChange, imageId, images, zProjection }: {
  schema: { properties: Record<string, ParameterSpec>; required: string[] };
  values: Record<string, ParameterValue>; onChange: (next: Record<string, ParameterValue>) => void;
  imageId: string; images: WorkbenchImage[]; zProjection?: string;
}) {
  const resolvedImage = useWorkbenchImage(imageId);
  const image = images.find((item) => item.id === imageId) ?? resolvedImage;
  const channelFields = Object.keys(schema.properties).filter((key) =>
    key === "channel" || key.endsWith("_channel") || key.startsWith("channel_"));
  const scalarSchema = { ...schema, properties: Object.fromEntries(Object.entries(schema.properties).filter(([key]) =>
    !["nuclearImageId", "somaImageId"].includes(key) && !channelFields.includes(key))) };
  return <>
    {channelFields.map((key) => {
      const channel = Number(values[key] ?? schema.properties[key].default ?? 0);
      return <label key={key}>{key.replaceAll("_", " ")}
        <select value={channel} onChange={(event) => onChange({ ...values, [key]: Number(event.target.value) })}>
          {channel >= (image?.channels ?? 1) ? <option value={channel} disabled>Channel {channel + 1} is unavailable in this image</option> : null}
          {Array.from({ length: image?.channels ?? 1 }, (_, index) => <option key={index} value={index}>Channel {index + 1}</option>)}
        </select>
      </label>;
    })}
    {(["nuclearImageId", "somaImageId"] as const).filter(key => schema.properties[key]).map(key => <div key={key}>
      <WorkbenchImageSelector label={key === "nuclearImageId" ? "Nuclear mask layer" : "Soma mask layer"}
        selectedIds={values[key] ? [String(values[key])] : []} onChange={ids => onChange({ ...values, [key]: ids[0] ?? "" })}
        filters={{ sourceHash: image?.sourceHash, analysisTarget: "plane" }}
        eligible={item => item.id !== imageId && item.parameters?.zProjection === (zProjection ?? image?.parameters?.zProjection)}
        eligibilityNote="Choose an independent saved mask over identical source pixels and projection. Paired object identities remain separate." />
    </div>)}
    <PluginParameters schema={scalarSchema} values={values} onChange={onChange} />
  </>;
}
