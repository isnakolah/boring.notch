#!/usr/bin/env python3
"""Build Boring Tutor Gateway release directory from one checked-out Tutor tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from calla_gateway_release import tree_digest


def copytree(source: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(".DS_Store", "__pycache__", ".build", "node_modules"))


def build_release(tutor: Path, output: Path, version: str) -> Path:
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(mode=0o700, parents=True)
    # Gateway/openclaw is Boring's canonical development plugin path. It is a
    # source-layout alias during migration, so the release has no Calla
    # checkout-path dependency.
    copytree(tutor / "Gateway/openclaw", output / "plugin")
    compiled_packs = tutor / "build" / "packs"
    if not compiled_packs.is_dir() or not any(compiled_packs.glob("*.otpack")):
        raise ValueError("compiled Tutor packs are missing; run `make pack-build` before building a Gateway release")
    copytree(compiled_packs, output / "packs")
    copytree(tutor / "agent-workspace", output / "agent-workspace")
    (output / "bin").mkdir()
    for name in ("calla-course-gateway.sh", "calla-course.sh"):
        source = tutor / "scripts" / name
        shutil.copy2(source, output / "bin" / name)
        (output / "bin" / name).chmod(0o700)
    (output / "migrations").mkdir()
    for name in ("calla_migration.py", "calla_openclaw_setup.py", "calla_pack_store.py", "calla_node_enroller.py"):
        shutil.copy2(tutor / "tools" / name, output / "migrations" / name)
    # Course preparation and pack installation resolve this directory through
    # the release root. Keep it release-contained: no Gateway checkout path.
    copytree(tutor / "tools", output / "migrations" / "tools")
    shutil.copy2(Path(__file__).resolve().parent / "calla_gateway_release.py", output / "bin" / "calla_gateway_release.py")
    manifest = {
        "releaseVersion": version,
        "gatewayDigest": tree_digest(output),
        "protocolRange": {"min": 2, "max": 3},
        "nodeContractHash": tree_digest(output / "plugin"),
        "packDigest": tree_digest(output / "packs"),
        "configMigrationVersion": 1,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tutor", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    print(build_release(args.tutor.resolve(), args.output.resolve(), args.version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
