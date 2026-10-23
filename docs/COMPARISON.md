# Microscopy software comparison

CellCounter brings segmentation, correction, measurements and experiment analysis into one
workbench, with desktop, command-line, Python and AI-agent access.

The [open-source feature matrix](../README.md#feature-comparison) compares the desktop app
with Cell-ACDC, Fiji, napari, CellProfiler and QuPath. Below are the source links and a look
at commercial alternatives. Updated **23 October 2026**.

**✓** included · **Plugin** extension · **?** undocumented

## Open-source tools

| Software | Features | Documentation |
| --- | --- | --- |
| **CellCounter** | Segmentation, mask editing, measurements, assays, review, workflows and portable analysis packages. The GUI, CLI, Python SDK and MCP server work with the same projects. | [Features](FEATURES.md), [Workbench](WORKBENCH.md), [editions](PLATFORM-PARITY.md) |
| **Cell-ACDC** | Live-cell segmentation and tracking, correction propagation, cell-cycle and lineage annotation, 3D segmentation and batch processing. Save workflow recipes and run them from the CLI, or add models and trackers through Python. | [Overview](https://cell-acdc.readthedocs.io/en/stable/overview.html), [application and batch processing](https://cell-acdc.readthedocs.io/en/stable/), [workflow implementation](https://github.com/SchmollerLab/Cell_ACDC/blob/main/cellacdc/segm.py#L932), [model interfaces](https://cell-acdc.readthedocs.io/en/stable/models.html) |
| **Fiji / ImageJ** | Image processing, measurement, macros and plugins. TrackMate adds tracking and lineage analysis; BigDataViewer handles multiresolution viewing. The Fiji LLM extension connects agents through MCP. | [ImageJ documentation](https://imagej.net/learn/), [TrackMate](https://imagej.net/plugins/trackmate/), [BigDataViewer](https://imagej.net/plugins/bdv/), [Fiji LLM / MCP](https://github.com/fiji/fiji-llm#mcp-server) |
| **napari** | Multidimensional viewing, volumetric label painting, shapes and tracks. Python and plugins add segmentation, measurement and tracking. The napari MCP plugin connects AI agents. | [Tutorials](https://napari.org/stable/tutorials/index.html), [label editing](https://napari.org/stable/howtos/layers/labels.html), [headless use](https://napari.org/stable/howtos/headless.html), [napari MCP](https://github.com/royerlab/napari-mcp) |
| **CellProfiler** | Quantitative analysis pipelines, morphology and intensity measurements, metadata grouping and headless batches. Plugins add learned segmentation. Tracking records splits, merges and lineage relationships. | [Application](https://cellprofiler.org/), [object-processing modules](https://cellprofiler-manual.s3.amazonaws.com/CellProfiler-4.2.8/modules/objectprocessing.html), [plugins](https://plugins.cellprofiler.org/supported_plugins.html), [headless and distributed execution](https://github.com/CellProfiler/CellProfiler/wiki/Adapting-CellProfiler-to-a-LIMS-environment) |
| **QuPath** | Whole-slide tissue imaging, region and object annotations, cell detection, fluorescence measurements and classification. StarDist adds learned nucleus detection. Groovy scripts automate projects and batches. | [First steps](https://qupath.readthedocs.io/en/stable/docs/starting/first_steps.html), [StarDist extension](https://qupath.readthedocs.io/en/stable/docs/deep/stardist.html), [command line](https://qupath.readthedocs.io/en/stable/docs/advanced/command_line.html) |

## Commercial alternatives

| Software | Segmentation and measurement | Imaging and tracking | Workflows and automation |
| --- | --- | --- | --- |
| **CellCounter** | Classical and learned segmentation, mask editing, cellular assays and biological-replicate statistics. | 3D threshold/watershed analysis, multiscale region viewing, tracking and division review. | Branching workflows, resumable jobs, CLI, Python SDK and MCP. [Feature guide](FEATURES.md). |
| **Imaris** | Spot, surface, cell and filament analysis, object statistics and colocalization. | 3D/4D visualization and analysis, TrackLineage motion tracking and lineage trees, stitching and deconvolution. | Saved protocols, Imaris Batch and Imaris XT customization with Python, MATLAB, Java and R. [Packages](https://imaris.oxinst.com/products/imaris-packages). |
| **ZEISS arivis Pro** | Classical, machine-learning and deep-learning segmentation, measurements and interactive object correction. | Large multidimensional datasets, 3D/4D analysis and tracking, and 3D semantic ONNX models. | Visual pipelines, batch processing, Python extensions and Microscopy Copilot help. [Product](https://www.zeiss.com/microscopy/en/products/software/arivis-pro.html), [4.6 release notes](https://knowledge.zeiss.com/rms/en/arivis-pro/release-notes/arivis-pro-4-6). |
| **Leica Aivia** | Learned segmentation, phenotyping, cellular and neuronal analysis, multiwell assays. | 2D/3D object analysis and tracking, multidimensional visualization and large-volume display. | Recipes, batch workflows and custom model integration across editions; multiwell condition summaries and dose-response analysis. [Product and editions](https://www.leica-microsystems.com/products/microscope-software/p/aivia/), [visualization and tracking](https://www.aivia-software.com/). |
| **Thermo Scientific Amira** | Interactive segmentation, morphology, intensity and spatial measurements for optical and electron microscopy. | 2D–5D workflows, large-volume visualization, learned 2D/3D segmentation and denoising. | Connected analysis modules, Python scripting and custom tools. [Amira](https://www.thermofisher.com/us/en/home/electron-microscopy/products/software-em-3d-vis/amira-software.html), [Python integration](https://www.thermofisher.com/us/en/home/electron-microscopy/products/software-em-3d-vis/python-scripting.html). |
| **Huygens** | Deconvolution and optical restoration, object measurements, colocalization and tracking tools. | Volume rendering, stitching, light-sheet fusion and object stabilization. | Workflow Processor, Batch Feeder and Huygens Core CLI, Python/Tcl scripting and server integration. [Products](https://svi.nl/Huygens-Products), [Core automation](https://svi.nl/Huygens-Core). |
| **IN Carta** | High-content segmentation, compartment measurements, SINAP deep learning and Phenoglyphs phenotyping. | Live-imaging analysis and 3D segmentation through Custom Module Editor's 3D application. | Custom protocols, parallel multiwell processing and monitored batches. [Product and modules](https://www.moleculardevices.com/products/cellular-imaging-systems/high-content-imaging/in-carta-image-analysis-software). |

## AI agents and scripting

Connect an AI agent to CellCounter through [MCP](WORKBENCH.md#mcp-connection), or use the
[CLI](WORKBENCH.md#cli-example) and [Python SDK](WORKBENCH.md#python-sdk) in your own scripts.
Agents can inspect images, run analyses, edit masks and export results using the same
operations as the desktop app. You choose their project and folder access.

Fiji and napari offer MCP through [Fiji LLM](https://github.com/fiji/fiji-llm#mcp-server)
and [napari MCP](https://github.com/royerlab/napari-mcp). Other scripting options include
ImageJ macros, Cell-ACDC recipes, CellProfiler pipelines, QuPath Groovy, Imaris XT and Amira Python.

For CellCounter's desktop and browser features, see the [edition comparison](PLATFORM-PARITY.md).
