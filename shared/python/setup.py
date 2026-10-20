"""Package only the shared runtime manifest, never repository/private material."""
from pathlib import Path
from setuptools import setup

ROOT = Path(__file__).resolve().parent


def requirements(name):
    return [line.strip() for line in (ROOT / name).read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


runtime_files = [line.strip() for line in (ROOT / "runtime-files.txt").read_text(encoding="utf-8").splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
modules = []
for name in runtime_files:
    if "/" in name or "\\" in name or name.startswith("."):
        raise ValueError("Runtime manifest entries must be flat filenames.")
    if name.endswith(".py"):
        modules.append(name[:-3])
setup(
    name="cellcounter-workbench",
    version="0.1.0",
    description="Local CellCounter GUI, CLI, MCP and Python operation runtime",
    license="MIT",
    license_files=["LICENSE"],
    long_description=(ROOT / "README.md").read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
    python_requires=">=3.11",
    py_modules=modules,
    install_requires=requirements("requirements-analysis.txt"),
    extras_require={"reporting": requirements("requirements-reporting.txt"), "mcp": requirements("requirements-mcp.txt"), "zarr": requirements("requirements-zarr.txt")},
    entry_points={"console_scripts": ["cellcounter-workbench=workbench:main"]},
    data_files=[("share/cellcounter-workbench", [str(ROOT / name) for name in
                ("runtime-files.txt", "requirements-analysis.txt", "requirements-mcp.txt", "requirements-zarr.txt", "requirements-reporting.txt", "requirements-omero.txt")])],
    include_package_data=False,
)
