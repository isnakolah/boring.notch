#!/usr/bin/env python3
"""Render the local, offline Calla pedagogy dashboard from capture-free JSONL."""
from __future__ import annotations
import argparse, json, statistics
from pathlib import Path

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    source = args.state_directory / "audit" / "pedagogy.jsonl"
    rows = []
    if source.is_file():
        for line in source.read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(line)
                if isinstance(row, dict): rows.append(row)
            except json.JSONDecodeError: pass
    first = [row["first_independent_success_ms"] for row in rows if isinstance(row.get("first_independent_success_ms"), (int, float))]
    feedback = [row["feedback_latency_ms"] for row in rows if isinstance(row.get("feedback_latency_ms"), (int, float))]
    html = """<!doctype html><title>Calla pedagogy dashboard</title><main><h1>Calla pedagogy dashboard</h1><p>Offline, capture-free evidence only.</p><dl><dt>Time to first independent successful performance</dt><dd>{first}</dd><dt>Median completion-to-feedback latency</dt><dd>{feedback}</dd></dl></main>""".format(
        first=f"{statistics.median(first):.0f} ms" if first else "No independent success recorded",
        feedback=f"{statistics.median(feedback):.0f} ms" if feedback else "No feedback latency recorded")
    output = args.output or args.state_directory / "audit" / "pedagogy-dashboard.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(html, encoding="utf-8")
    print(output)
    return 0
if __name__ == "__main__": raise SystemExit(main())
