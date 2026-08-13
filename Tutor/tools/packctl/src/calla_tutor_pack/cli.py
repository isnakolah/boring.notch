from __future__ import annotations

import argparse
import json
import sys

from .compiler import PackError, compile_pack, search_pack, validate_pack


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="calla-tutor-pack", description="Validate and compile Calla Tutor App Packs")
    subcommands = parser.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate", help="validate a source App Pack")
    validate.add_argument("pack")

    compile_command = subcommands.add_parser("compile", help="compile a source App Pack into an .otpack bundle")
    compile_command.add_argument("pack")
    compile_command.add_argument("--output", required=True)

    search = subcommands.add_parser("search", help="search a compiled App Pack")
    search.add_argument("pack")
    search.add_argument("query")
    search.add_argument("--limit", type=int, default=5)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "validate":
            result = validate_pack(args.pack)
            print(
                json.dumps(
                    {
                        "ok": True,
                        "pack_id": result.manifest["id"],
                        "pack_version": result.manifest["pack_version"],
                        "entities": len(result.entities),
                    },
                    sort_keys=True,
                )
            )
            return 0
        if args.command == "compile":
            result = compile_pack(args.pack, args.output)
            print(
                json.dumps(
                    {
                        "ok": True,
                        "pack_id": result.pack_id,
                        "pack_version": result.pack_version,
                        "entities": result.entity_count,
                        "output": str(result.output_path),
                    },
                    sort_keys=True,
                )
            )
            return 0
        if args.command == "search":
            print(json.dumps(search_pack(args.pack, args.query, args.limit), indent=2, ensure_ascii=False))
            return 0
        raise AssertionError(f"unknown command: {args.command}")
    except PackError as exc:
        print(str(exc), file=sys.stderr)
        return 2
