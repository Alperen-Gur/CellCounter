import Foundation

/// A user-requested readiness check. Ordinary science does not import the MCP SDK.
enum WorkbenchRuntimeReadiness {
    struct Result: Sendable {
        let ready: Bool
        let summary: String
    }

    static func check() async -> Result {
        let python = FileStore.shared.pythonDir.appendingPathComponent("venv_workbench/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return Result(ready: false, summary: "The dedicated Workbench environment is not installed. Existing model environments are separate.")
        }
        guard let requirements = PythonRuntime.bundledPythonURL(named: "requirements-mcp.txt"),
              let analysisRequirements = PythonRuntime.bundledPythonURL(named: "requirements-analysis.txt"),
              let zarrRequirements = PythonRuntime.bundledPythonURL(named: "requirements-zarr.txt"),
              let reportingRequirements = PythonRuntime.bundledPythonURL(named: "requirements-reporting.txt") else {
            return Result(ready: false, summary: "This application is missing a standard Workbench requirements file. Reinstall the application.")
        }
        // Read the single shipped version pin instead of duplicating it in Swift.
        let script = #"""
import contextlib, importlib, importlib.metadata, io, json, pathlib, signal, sys
signal.alarm(20)
try:
    if sys.version_info < (3, 11):
        raise RuntimeError("Python 3.11 or later is required. Install or repair to use a supported interpreter.")
    lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    pinned = next(line.strip().split("==", 1)[1] for line in lines if line.strip().startswith("mcp=="))
    for requirements_path in sys.argv[1:]:
        for line in pathlib.Path(requirements_path).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            package, required = line.split("==", 1)
            package = package.split("[", 1)[0]
            observed = importlib.metadata.version(package)
            if observed != required:
                raise RuntimeError(package + " " + required + " is required; installed " + observed + ".")
    installed = importlib.metadata.version("mcp")
    if installed != pinned:
        raise RuntimeError("MCP " + pinned + " is required; the installed version is " + installed + ".")
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        for module in ("numpy", "scipy.ndimage", "PIL.Image", "skimage.measure", "tifffile",
                       "packaging", "zarr", "numcodecs", "matplotlib.figure", "mcp.server", "mcp.server.stdio"):
            try:
                importlib.import_module(module)
            except Exception as exc:
                raise RuntimeError(module + " could not load: " + str(exc) + ". Use Install or repair.") from exc
    print(json.dumps({"ready": True, "summary": "Ready: Python " + sys.version.split()[0] + " and MCP " + installed + "."}))
except Exception as exc:
    print(json.dumps({"ready": False, "summary": str(exc)}))
"""#
        do {
            let result = try await SidecarProcessRunner.run(pythonURL: python,
                args: ["-I", "-c", script, requirements.path, analysisRequirements.path, zarrRequirements.path, reportingRequirements.path], trackerKind: .other)
            guard result.exitCode == 0,
                  let value = try? JSONDecoder().decode(WorkbenchJSON.self, from: result.stdout) else {
                return Result(ready: false, summary: "The Python environment could not complete its readiness check. Use Install or repair, then check again.")
            }
            return Result(ready: value["ready"].bool == true,
                          summary: value["summary"].string ?? "The local environment needs repair.")
        } catch {
            return Result(ready: false, summary: "Readiness check failed: \(error.localizedDescription)")
        }
    }
}
