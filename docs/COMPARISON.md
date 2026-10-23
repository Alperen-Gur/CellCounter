# Microscopy software comparison

CellCounter combines image analysis, correction, measurements and saved project history with
shared GUI, CLI, Python SDK and MCP operations. Other platforms offer different strengths in
live-cell analysis, large volumes, tissue imaging, restoration or high-content screening.

The [open-source feature matrix](../README.md#feature-comparison) provides a compact overview.
This page explains its entries and compares selected commercial alternatives using primary
project and vendor documentation reviewed on **23 October 2026**.

CellCounter entries refer to the released desktop Workbench in **macOS 1.1.0** and
**Windows 1.3.0**. The **Web 0.3.2 preview** has a smaller feature set; see the
[platform comparison](PLATFORM-PARITY.md). This comparison describes documented capabilities,
not measured accuracy, throughput or usability. It is selective rather than exhaustive.

## Reading the feature matrix

| Entry | Meaning |
| --- | --- |
| **✓** | The cited documentation describes support in the application. |
| **Plugin** | An extension supplies the capability. Some extensions ship with the application; others require installation or configuration. |
| **Limited** | Support has a material dimensional, dataset or method restriction, explained below. |
| **?** | The reviewed sources do not establish the capability. This does not establish that it is unavailable. |
| Named route | The cell identifies a particular method, component, interface or dimensional limit. |

Opening a z-stack is different from segmenting objects volumetrically. Multiscale viewing is
different from running every algorithm out of core. A macro, API, copilot and MCP server also
provide different forms of automation. The matrix preserves these distinctions.

## Open-source tools: scope and sources

| Software | Scope and qualifications | Primary documentation |
| --- | --- | --- |
| **CellCounter** | Segmentation, exact corrections, measurements, assays, review, workflows and portable analysis packages. GUI, CLI, SDK and MCP use shared project operations. Selected-volume analysis and tracking have explicit limits. | [Features](FEATURES.md), [Workbench](WORKBENCH.md), [platforms](PLATFORM-PARITY.md) |
| **Cell-ACDC** | Segmentation, live-cell tracking, correction propagation, cell-cycle and lineage annotation. Integrated models include classical and learned methods; 3D segmentation and batch processing are documented. Saved workflow recipes can run through its CLI; Python interfaces allow additional models and trackers. | [Overview](https://cell-acdc.readthedocs.io/en/stable/overview.html), [application and batch processing](https://cell-acdc.readthedocs.io/en/stable/), [workflow implementation](https://github.com/SchmollerLab/Cell_ACDC/blob/main/cellacdc/segm.py#L932), [model interfaces](https://cell-acdc.readthedocs.io/en/stable/models.html) |
| **Fiji / ImageJ** | General image processing, measurement and scripting, with a broad plugin ecosystem. TrackMate supplies tracking and lineage tools; BigDataViewer supplies tiled multiresolution viewing. The optional Fiji LLM extension provides MCP access to a running Fiji application. | [ImageJ documentation](https://imagej.net/learn/), [TrackMate](https://imagej.net/plugins/trackmate/), [BigDataViewer](https://imagej.net/plugins/bdv/), [Fiji LLM / MCP](https://github.com/fiji/fiji-llm#mcp-server) |
| **napari** | Multidimensional viewing, labels, shapes and track display, including volumetric label painting and lazy/multiscale arrays. Analysis, measurement and automatic tracking commonly use Python or plugins. MCP access is available through a third-party plugin. | [Tutorials](https://napari.org/stable/tutorials/index.html), [label editing](https://napari.org/stable/howtos/layers/labels.html), [headless use](https://napari.org/stable/howtos/headless.html), [napari MCP](https://github.com/royerlab/napari-mcp) |
| **CellProfiler** | Saved quantitative-analysis pipelines, morphology and intensity measurements, metadata grouping and headless batch execution. Learned segmentation is available through plugins. Some segmentation/measurement modules support 3D; `EditObjectsManually` and `TrackObjects` are 2D. Tracking includes splits, merges and lineage relationships. | [Application](https://cellprofiler.org/), [object-processing module dimensions](https://cellprofiler-manual.s3.amazonaws.com/CellProfiler-4.2.8/modules/objectprocessing.html), [supported plugins](https://plugins.cellprofiler.org/supported_plugins.html), [headless and distributed execution](https://github.com/CellProfiler/CellProfiler/wiki/Adapting-CellProfiler-to-a-LIMS-environment) |
| **QuPath** | Whole-slide tissue imaging, regions and object annotations, cell detection, fluorescence measurements and classification. Learned nucleus detection is available through the StarDist extension. Project scripts can run in batches and headlessly. ROI/object editing should not be read as an equivalent volumetric label editor. | [First steps](https://qupath.readthedocs.io/en/stable/docs/starting/first_steps.html), [StarDist extension](https://qupath.readthedocs.io/en/stable/docs/deep/stardist.html), [command line](https://qupath.readthedocs.io/en/stable/docs/advanced/command_line.html) |

In the matrix, **reusable analysis** includes saved configurations, pipelines, macros or scripts;
it does not imply that all products provide a visual workflow editor. **Batch analysis** does
not imply an automated cluster scheduler. A Python extension interface is not equivalent to a
complete analysis API.

## Commercial alternatives

Commercial products often divide capabilities among editions, modules or connected services.
The entries below describe documented product capabilities; they do not assert that every
feature is included in a base license. Confirm the required configuration with the vendor.

| Software | Segmentation, measurements and scientific focus | Volumes, tracking and data scale | Workflows and extension routes |
| --- | --- | --- | --- |
| **CellCounter** | Classical methods and configured 2D learned adapters; mask corrections, measurements, assays, review and specimen-level statistics. | Bounded 3D segmentation/editing/measurements; selected tiled and multiscale operations; tracking and reviewed division proposals. | Saved branching workflows and resumable jobs; shared CLI, Python SDK and scoped MCP. [Current scope](FEATURES.md#current-operating-limits). |
| **Imaris** | Spot, surface, cell and filament analysis; object statistics and colocalization, depending on package. | 3D/4D visualization and analysis; TrackLineage supplies motion tracking, divisions and lineage trees; stitching and deconvolution components. | Saved workflows; Imaris Batch for saved-protocol processing; Imaris XT for Python, MATLAB, Java and R customization. Package contents vary. [Package comparison](https://imaris.oxinst.com/products/imaris-packages). |
| **ZEISS arivis Pro** | Classical, machine-learning and deep-learning segmentation; measurements and interactive object correction. | Large multidimensional datasets; 3D/4D analysis and tracking. Version 4.6 supports externally trained 3D semantic ONNX models. | Visual analysis pipelines, batch processing and Python extension routes. Version 4.6's Microscopy Copilot provides application guidance; this is not evidence of a general MCP operation interface. [Product](https://www.zeiss.com/microscopy/en/products/software/arivis-pro.html), [4.6 release notes](https://knowledge.zeiss.com/rms/en/arivis-pro/release-notes/arivis-pro-4-6). |
| **Leica Aivia** | Learned segmentation, phenotyping, cellular and neuronal analysis; guided multiwell assays. | 2D/3D object analysis and tracking, multidimensional visualization and large-volume display. | Recipes and batch workflows; selected editions support custom or third-party deep-learning models. Multiwell analysis includes condition aggregation and dose-response workflows. [Product and editions](https://www.leica-microsystems.com/products/microscope-software/p/aivia/), [visualization and tracking](https://www.aivia-software.com/). |
| **Thermo Scientific Amira** | Interactive segmentation, morphology, intensity and spatial measurements; optical/electron microscopy and other volumetric imaging. | 2D–5D workflows, large-volume visualization and analysis; shallow/deep-learning 2D/3D segmentation and denoising. | Connected analysis modules and Python scripting; custom analysis tools and managed Python environments. Capability availability depends on the edition/extensions. [Amira](https://www.thermofisher.com/us/en/home/electron-microscopy/products/software-em-3d-vis/amira-software.html), [Python integration](https://www.thermofisher.com/us/en/home/electron-microscopy/products/software-em-3d-vis/python-scripting.html). |
| **Huygens** | Deconvolution and optical restoration; optional object, colocalization and tracking analysis. | Volumetric rendering, PSF-related restoration, stitching, light-sheet fusion and object stabilization through relevant products. | Workflow Processor and Batch Feeder; Huygens Core provides CLI, Python/Tcl scripting and server integration. Modules and access modes vary. [Product comparison](https://svi.nl/Huygens-Products), [Core automation](https://svi.nl/Huygens-Core). |
| **IN Carta** | High-content segmentation, compartment measurements and phenotyping; SINAP deep-learning and Phenoglyphs analysis modules. | Live-imaging analysis; true 3D segmentation is supplied by the Custom Module Editor's **3D application**. | Guided custom protocols, parallel multiwell processing and monitored batches. Custom Module Editor, SINAP and Phenoglyphs are distinct applications/modules. [Product and module documentation](https://www.moleculardevices.com/products/cellular-imaging-systems/high-content-imaging/in-carta-image-analysis-software). |

These tools are not interchangeable in every experiment. Cell-ACDC emphasizes live-cell
correction and cell-cycle annotation; QuPath emphasizes tissue slides; Huygens emphasizes
restoration; IN Carta emphasizes high-content assays. Hardware integration, support contracts
and institutional deployment can also influence the choice.

## Automation and AI-agent access

| Route | Documented examples | What the comparison establishes |
| --- | --- | --- |
| Shared project operations and MCP | [CellCounter CLI, SDK and MCP](WORKBENCH.md#mcp-connection) | Documented operations with project revisions, request identifiers and explicit access grants. |
| MCP extension to an interactive application | [Fiji LLM](https://github.com/fiji/fiji-llm#mcp-server), [napari MCP](https://github.com/royerlab/napari-mcp) | Optional agent interfaces; extension installation, running application state and tool permissions affect their use. napari MCP is a third-party project. |
| Scripts, APIs and plugins | ImageJ macros/APIs, napari Python, CellProfiler CLI/modules, QuPath Groovy/CLI, Imaris XT, Amira Python | Programmatic access exists without requiring a particular conversational interface. Coverage and execution environments differ. |
| In-application copilot | [arivis Pro 4.6 Microscopy Copilot](https://knowledge.zeiss.com/rms/en/arivis-pro/release-notes/arivis-pro-4-6) | Vendor documentation describes help with learning the application. It does not establish the same operation or permission model as an MCP server. |

An unknown MCP entry is not a claim that a product cannot be controlled by an agent. Agents
can also use supported APIs or command-line tools. No assertion of exclusive AI-agent access
is made here.

## CellCounter limits relevant to comparison

| Area | Published desktop scope |
| --- | --- |
| 3D analysis | Up to **8 million voxels per selected scientific volume**. Rendering uses at most **128 samples per axis**; scientific measurements and edits use the original selected voxels. |
| Learned models | The registered Cellpose, StarDist, Omnipose and micro-SAM routes currently perform **2D inference**, with separately configured dependencies and checkpoints. |
| Large sources | Bounded original-resolution TIFF/NGFF regions and selected tiled threshold/connected-component analysis. General tiled learned-model inference is not included. |
| Tracking and correction | Displacement/gap controls, link edits and reviewed heuristic division proposals. Temporal correction propagation is bounded and requires review. |
| Correction-aware results | Mask edits update canonical measurements. Supported dependent results are marked stale and refreshed explicitly; registration refresh reapplies stored transforms, and exported reports are not universally regenerated. |
| Workflows | Branching graphs, sweeps and resumable jobs. Branches execute sequentially; general conditional execution and automated cluster scheduling are not provided. |
| Reproducibility | Packages retain inputs, parameters, methods and history. Environment inventories are records of observed versions, not installable dependency lockfiles. |

See the [feature guide](FEATURES.md) and [operation-specific scope](WORKBENCH.md#current-scope-and-troubleshooting)
before selecting an analysis route. Numerical and biological comparisons require a specified
dataset, configured methods, hardware and evaluation protocol; the presence of a feature alone
does not establish a scientific performance advantage.
