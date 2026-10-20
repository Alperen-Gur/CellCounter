import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { request } from "../../kernel/workbench/client";
import type { OmeroProfile } from "../../../../shared/workbench/omeroProtocol";

interface RuntimeStatus {
  installed: boolean; ready: boolean; analysisReady: boolean; mcpReady: boolean; storageReady?: boolean; reportingReady?: boolean;
  pythonVersion?: string; microscopyBundled: boolean; message?: string;
  packages: { name: string; version?: string; available: boolean; reason?: string }[];
}
interface Props {
  path: string; busy: boolean; writeBlocked: boolean;
  run: (action: () => Promise<void>) => Promise<void>;
  chooseFolder: (accepted: (path: string) => void) => Promise<void>;
}

export default function WorkbenchAgentAccess({ path, busy, writeBlocked, run, chooseFolder }: Props) {
  const [runtime, setRuntime] = useState<RuntimeStatus>();
  const [logs, setLogs] = useState<string[]>([]);
  const [installing, setInstalling] = useState(false);
  const [toolMode, setToolMode] = useState<"compact" | "operations">("compact");
  const [allowWrite, setAllowWrite] = useState(false);
  const [allowPlugins, setAllowPlugins] = useState(false);
  const [allowPaths, setAllowPaths] = useState<string[]>([]);
  const [omeroProfiles, setOmeroProfiles] = useState<OmeroProfile[]>([]);
  const [allowOmeroProfiles, setAllowOmeroProfiles] = useState<string[]>([]);
  const [allowOmeroConfiguration, setAllowOmeroConfiguration] = useState(false);
  const [configuration, setConfiguration] = useState<{ key: string; value: string }>();
  const [copied, setCopied] = useState(false);
  const alive = useRef(true);
  const key = JSON.stringify([path, toolMode, allowWrite, allowPlugins, allowPaths, allowOmeroProfiles, allowOmeroConfiguration]);
  const currentConfiguration = configuration?.key === key ? configuration.value : "";

  useEffect(() => {
    alive.current = true;
    const registration = listen<{ modelId: string; line: string }>("env://install/log", ({ payload }) => {
      if (alive.current && payload.modelId === "workbench") setLogs(previous => [...previous.slice(-79), payload.line]);
    });
    return () => { alive.current = false; void registration.then(unlisten => unlisten()).catch(() => undefined); };
  }, []);

  const inspect = () => run(async () => {
    const result = await invoke<RuntimeStatus>("workbench_runtime_status");
    if (alive.current) setRuntime(result);
  });
  const install = () => run(async () => {
    setInstalling(true); setLogs([]); setRuntime(undefined);
    try {
      await invoke("workbench_runtime_install");
      const result = await invoke<RuntimeStatus>("workbench_runtime_status");
      if (alive.current) setRuntime(result);
    } finally { if (alive.current) setInstalling(false); }
  });
  const generate = () => run(async () => {
    const result = await invoke<Record<string, unknown>>("workbench_connection", {
      projectPath: path, toolMode, allowWrite, allowPlugins, allowPaths, allowOmeroProfiles, allowOmeroConfiguration,
    });
    if (alive.current) { setConfiguration({ key, value: JSON.stringify(result, null, 2) }); setCopied(false); }
  });

  return <details className="workbench-agent-access">
    <summary>AI agent access</summary>
    <p>GUI, CLI and MCP use the same project operations, revisions and history. The installed application provides the command; no private Python path is needed.</p>
    <div className="workbench-actions">
      <button className="cc-btn" disabled={busy} onClick={() => void inspect()}>Check runtime readiness</button>
      <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void install()}>{installing ? "Installing runtime…" : "Install or repair runtime"}</button>
    </div>
    <p role="status">{runtime ? runtime.ready ? `Workbench runtime ready · Python ${runtime.pythonVersion} · analysis, MCP, chunked storage and reporting available`
      : runtime.installed ? "Workbench runtime needs repair. See dependency details below." : runtime.message
      : "Readiness has not been checked. Installation downloads the pinned analysis, MCP, chunked storage and reporting dependencies into a dedicated environment."}</p>
    <p>Existing model environments stay separate. Agent commands never install software automatically.</p>
    {runtime && !runtime.microscopyBundled ? <p>Packaged layer-workspace operations need the microscopy runtime from a complete application release.</p> : null}
    {runtime?.packages.length ? <details><summary>Runtime dependency details</summary><ul>{runtime.packages.map(item => <li key={item.name}>
      {item.name}: {item.available ? item.version : item.reason || "Unavailable"}
    </li>)}</ul></details> : null}
    {logs.length ? <details open={installing}><summary>Installation output</summary><pre className="workbench-agent-log">{logs.join("\n")}</pre></details> : null}
    <fieldset disabled={busy || !path}>
      <legend>Current project connection</legend>
      {!path ? <p>Create or open a project to configure its agent connection.</p> : <p className="workbench-project-path">{path}</p>}
      <label>Agent tool discovery<select value={toolMode} onChange={event => setToolMode(event.target.value as "compact" | "operations")}><option value="compact">Compact discovery · discover, read and mutate</option><option value="operations">Individual operation tools</option></select></label>
      <p>Both modes use the same operation schemas and permission grants. Compact discovery loads relevant operation details on demand.</p>
      <label><input type="checkbox" checked={allowWrite} onChange={event => { setAllowWrite(event.target.checked); if (!event.target.checked) { setAllowPlugins(false); setAllowOmeroConfiguration(false); } }} /> Allow project writes</label>
      <label><input type="checkbox" checked={allowPlugins} disabled={!allowWrite} onChange={event => setAllowPlugins(event.target.checked)} /> Allow executable plugins and registered model methods</label>
      <p>Read-only access is the default. Executable methods run trusted local code and require both grants.</p>
      <details><summary>Additional source and export folders</summary>
        <p>Grant only the folders this agent needs for imports or exports outside the project.</p>
        <ul>{allowPaths.map(folder => <li key={folder}><span className="workbench-project-path">{folder}</span>{" "}<button className="cc-btn" onClick={() => setAllowPaths(previous => previous.filter(value => value !== folder))}>Remove folder grant</button></li>)}</ul>
        <button className="cc-btn" disabled={allowPaths.length >= 32} onClick={() => void chooseFolder(folder => setAllowPaths(previous => previous.includes(folder) ? previous : [...previous, folder]))}>Choose allowed folder…</button>
      </details>
      <details><summary>OMERO connection scope</summary>
        <p>Each selected profile permits read-only network access to its configured server. Importing raw pixels also requires project writes. Credential values are never included in this configuration.</p>
        <button className="cc-btn" onClick={() => void run(async () => {
          const value = await request<{ profiles: OmeroProfile[] }>("", "omero.profile.list");
          setOmeroProfiles(value.profiles); setAllowOmeroProfiles(previous => previous.filter(id => value.profiles.some(profile => profile.id === id)));
        })}>Load named profile grants</button>
        {omeroProfiles.map(profile => <label key={profile.id}><input type="checkbox" checked={allowOmeroProfiles.includes(profile.id)} onChange={event => setAllowOmeroProfiles(previous => event.target.checked ? [...previous, profile.id] : previous.filter(id => id !== profile.id))} />{profile.name} · {profile.host} · {profile.id}</label>)}
        <label><input type="checkbox" disabled={!allowWrite} checked={allowOmeroConfiguration} onChange={event => setAllowOmeroConfiguration(event.target.checked)} /> Allow changes to host-local OMERO profiles and interpreter binding</label>
        {allowOmeroConfiguration ? <p>Grant only the required interpreter, credential-reference and CA folders above. Runtime probing additionally requires the executable-code grant.</p> : null}
      </details>
      <button className="cc-btn" onClick={() => void generate()}>Generate connection configuration</button>
    </fieldset>
    {configuration && !currentConfiguration ? <p>Connection settings changed. Generate the configuration again before using it.</p> : null}
    {currentConfiguration ? <>
      <label>MCP client configuration<textarea className="workbench-agent-config" rows={12} readOnly value={currentConfiguration} spellCheck={false} onFocus={event => event.currentTarget.select()} /></label>
      <button className="cc-btn" disabled={busy || !navigator.clipboard} onClick={() => void run(async () => { await navigator.clipboard.writeText(currentConfiguration); setCopied(true); })}>{copied ? "Configuration copied" : "Copy configuration"}</button>
      {!navigator.clipboard ? <p>Select and copy the configuration above.</p> : null}
      {runtime?.ready !== true ? <p>Install or repair the runtime and check readiness before connecting.</p> : null}
    </> : null}
  </details>;
}
