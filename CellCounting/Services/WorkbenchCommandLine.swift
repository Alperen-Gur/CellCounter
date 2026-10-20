import Darwin
import Foundation

/// A stable installed-app entry point. All commands and MCP protocol handling
/// stay in workbench.py; this launcher only selects the bundled local runtime.
@MainActor
enum WorkbenchCommandLine {
    static let flag = "--workbench"

    static func handleIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == flag else { return }
        do {
            let forwarded = Array(arguments.dropFirst())
            func hasOption(_ name: String) -> Bool {
                forwarded.contains { $0 == name || $0.hasPrefix(name + "=") }
            }
            let pythonDirectory = FileStore.location().appendingPathComponent("python", isDirectory: true)
            let python = PythonRuntime.workbenchInterpreter(pythonDirectory: pythonDirectory)
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw WorkbenchFailure(code: "runtime-unavailable", message: "The installed workbench Python environment is unavailable. Install it once from CellCounter’s AI agent and command-line access panel, then retry this command. No library was opened or changed.")
            }
            let script = try PythonRuntime.stageWorkbenchSnapshot(pythonDirectory: pythonDirectory)
            var command = [python.path, script.path]
            if !hasOption("--omero-profiles") {
                command += ["--omero-profiles", WorkbenchOmeroConfiguration.registryURL.path]
            }
            if !hasOption("--native-helper"), let helper = Bundle.main.executableURL {
                command += ["--native-helper", helper.path]
            }
            // MCP and request commands may call any microscopy tool later.
            // Bind the bundled runtime once at process startup. Explicit CLI
            // configuration remains available for a trusted host-local runtime.
            if !hasOption("--microscopy-node") && !hasOption("--microscopy-runtime") {
                do {
                    let microscopy = try MicroscopyRuntime.stage(pythonDirectory: pythonDirectory)
                    command += ["--microscopy-node", microscopy.nodeURL.path,
                                "--microscopy-runtime", microscopy.manifestURL.deletingLastPathComponent().path]
                } catch {
                    // Node is optional for ordinary analysis and metadata reads.
                    // Worker-backed tools fail explicitly if no trusted binding
                    // is available; never fall back to PATH or install packages.
                    FileHandle.standardError.write(Data("Optional microscopy runtime unavailable: \(error.localizedDescription)\n".utf8))
                }
            }
            command += forwarded
            var cArguments = command.map { strdup($0) }
            cArguments.append(nil)
            defer { for pointer in cArguments { free(pointer) } }
            let code = cArguments.withUnsafeMutableBufferPointer { argv in
                Darwin.execv(python.path, argv.baseAddress!)
            }
            if code == -1 {
                let message = String(cString: strerror(errno))
                throw WorkbenchFailure(code: "runtime-launch", message: "Could not start the canonical workbench runtime: \(message)")
            }
        } catch {
            let failure = error as? WorkbenchFailure
            let message = "CellCounter \(failure?.code ?? "startup-failed"): \(error.localizedDescription)\n"
            // MCP stdout is reserved for protocol messages even during failure.
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(1)
        }
    }
}
