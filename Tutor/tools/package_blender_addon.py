#!/usr/bin/env python3
"""Build the legacy Blender add-on ZIP used by the Phase 0 Mac test path."""

from __future__ import annotations

import argparse
import json
import stat
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_ROOT = REPOSITORY_ROOT / "bridges" / "blender"
ADDON_PACKAGE = "calla_tutor_blender"
DEFAULT_OUTPUT = REPOSITORY_ROOT / "build" / "blender" / "calla-tutor-blender-0.3.0.zip"
PACKAGE_FILES = {
    BRIDGE_ROOT / "addon.py": f"{ADDON_PACKAGE}/__init__.py",
    BRIDGE_ROOT / ADDON_PACKAGE / "observer.py": f"{ADDON_PACKAGE}/observer.py",
    BRIDGE_ROOT / ADDON_PACKAGE / "protocol.py": f"{ADDON_PACKAGE}/protocol.py",
    BRIDGE_ROOT / ADDON_PACKAGE / "server.py": f"{ADDON_PACKAGE}/server.py",
}


def build_addon(output: Path) -> dict[str, object]:
    """Create a deterministic ZIP with the package layout Blender expects."""

    missing = [str(source) for source in PACKAGE_FILES if not source.is_file()]
    if missing:
        raise FileNotFoundError(f"missing Blender add-on sources: {missing}")

    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source, archive_name in sorted(PACKAGE_FILES.items(), key=lambda item: item[1]):
            content = source.read_bytes()
            compile(content, str(source), "exec")
            info = zipfile.ZipInfo(archive_name, date_time=(2026, 8, 9, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(info, content)

    return {
        "ok": True,
        "output": str(output),
        "files": sorted(PACKAGE_FILES.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    print(json.dumps(build_addon(args.output), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
