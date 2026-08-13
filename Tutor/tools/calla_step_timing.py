#!/usr/bin/env python3
"""Split a Calla teaching step into where its seconds actually went.

A lesson step is slow for exactly one reason at a time, and guessing which is
how the wrong thing gets optimised. This reads the timestamps the runtime
already writes and prints the split: how long the turn took, how many model
calls it needed, how long each one waited, and how much context it carried.

    python3 tools/calla_step_timing.py --last 5

Run it on the Gateway, or over ssh from the Mac:

    ssh gateway 'python3 - --last 5' < tools/calla_step_timing.py

Two sources, because they answer different questions:

* The codex rollout (`--source rollout`, the default) has per-event timestamps,
  so it can separate backend setup from each individual model call. This is the
  one that says "three model calls at eight seconds each".
* The OpenClaw session store (`--source store`) only timestamps turn
  boundaries, because tool events are mirrored in a batch when the turn ends.
  It cannot see inside a turn, but it covers every turn ever taken and is the
  right source for a median over a long history.

Metadata only: tool names, durations, and token counts. No prompt text, no tool
arguments, no capture data, and nothing carrying a window title or a filename.
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import statistics
import sys
from pathlib import Path

# The tools whose latency is the product. Anything else in a turn is overhead
# worth seeing named.
TUTOR_TOOLS = {
    "tutor_observe", "tutor_retrieve", "tutor_plan", "tutor_guide",
    "tutor_await_change", "tutor_narrate", "tutor_point",
    "tutor_propose_action", "tutor_verify",
}


def parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def agent_directory(agent: str) -> Path:
    return Path.home() / ".openclaw" / "agents" / agent


def rollout_files(agent: str) -> list[Path]:
    pattern = str(agent_directory(agent) / "agent" / "codex-home" / "sessions" / "*" / "*" / "*" / "*.jsonl")
    return sorted((Path(path) for path in glob.glob(pattern)), key=os.path.getmtime)


def read_jsonl(path: Path):
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def turns_from_rollout(path: Path) -> list[dict]:
    """One entry per task_started..task_complete, with the model gaps inside it.

    A "model call" here is the wait between the runtime having everything it
    needs and the model emitting its next action: from the previous tool result
    (or from the turn's first prepared context) to the next tool call. That gap
    is prefill plus reasoning plus generation, and it is what the learner is
    sitting through.
    """
    turns: list[dict] = []
    current: dict | None = None
    previous: dt.datetime | None = None

    for record in read_jsonl(path):
        stamp = record.get("timestamp")
        if not stamp:
            continue
        when = parse_timestamp(stamp)
        payload = record.get("payload") or {}
        kind = payload.get("type") or record.get("type")

        if kind == "task_started":
            current = {"file": path.name, "started": when, "setup": None, "calls": [],
                       "tokens": {}, "context_window": None}
            previous = when
            continue
        if current is None:
            continue

        # The first prepared context marks the end of session setup: everything
        # before it is resuming the rollout, not thinking about this step.
        if current["setup"] is None and kind in {"response_item", "turn_context", "world_state"}:
            current["setup"] = (when - current["started"]).total_seconds()
            previous = when

        if kind in {"custom_tool_call", "function_call"}:
            name = payload.get("name") or "(unnamed)"
            current["calls"].append({
                "tool": str(name),
                "wait_seconds": round((when - previous).total_seconds(), 1) if previous else None,
                "at_seconds": round((when - current["started"]).total_seconds(), 1),
            })
        elif kind in {"custom_tool_call_output", "function_call_output"}:
            previous = when
        elif kind == "token_count":
            # `total_token_usage` accumulates over the whole session and climbs
            # into the millions, which reads as a per-step cost and is not one.
            # `last_token_usage` is what the model call that just finished
            # actually carried, so attach it to that call and report the turn by
            # its largest prefill.
            info = payload.get("info") or {}
            usage = info.get("last_token_usage") or {}
            if not usage:
                continue
            if current["calls"]:
                current["calls"][-1]["tokens"] = usage
            best = current["tokens"].get("input_tokens", 0)
            if usage.get("input_tokens", 0) >= best:
                current["tokens"] = dict(usage)
            if info.get("model_context_window"):
                current["context_window"] = info["model_context_window"]
        elif kind == "task_complete":
            current["total_seconds"] = round((when - current["started"]).total_seconds(), 1)
            turns.append(current)
            current = None
            previous = None

    return turns


def turns_from_store(agent: str, session: str | None) -> list[dict]:
    """Turn boundaries from the OpenClaw session store.

    Tool events are mirrored in a batch at turn end, so intra-turn gaps collapse
    to zero here and only the total is meaningful. That total is still the right
    number for "how long does a step take", over far more history than the
    rollouts keep.
    """
    directory = agent_directory(agent) / "sessions"
    paths = sorted(directory.glob("*.jsonl"), key=os.path.getmtime) if directory.is_dir() else []
    paths = [p for p in paths if not p.name.endswith(".trajectory.jsonl")]
    if session:
        paths = [p for p in paths if p.stem == session]

    turns: list[dict] = []
    for path in paths:
        pending: dt.datetime | None = None
        for record in read_jsonl(path):
            if record.get("type") != "message":
                continue
            message = record.get("message") or {}
            when = parse_timestamp(record["timestamp"])
            role = message.get("role")
            if role == "user":
                pending = when
            elif role in {"assistant", "toolResult"} and pending is not None:
                turns.append({
                    "file": path.name,
                    "started": pending,
                    "total_seconds": round((when - pending).total_seconds(), 1),
                    "setup": None,
                    "calls": [],
                    "tokens": {},
                    "context_window": None,
                })
                pending = None
    turns.sort(key=lambda turn: turn["started"])
    return turns


def summarise(turns: list[dict]) -> dict:
    totals = sorted(turn["total_seconds"] for turn in turns if turn.get("total_seconds") is not None)
    waits = [call["wait_seconds"] for turn in turns for call in turn["calls"] if call["wait_seconds"] is not None]
    counts = [len(turn["calls"]) for turn in turns if turn["calls"]]
    inputs = [turn["tokens"].get("input_tokens") for turn in turns if turn["tokens"].get("input_tokens")]
    cached = [turn["tokens"].get("cached_input_tokens") for turn in turns if turn["tokens"].get("cached_input_tokens")]

    def spread(values: list[float]) -> dict | None:
        if not values:
            return None
        ordered = sorted(values)
        return {
            "n": len(ordered),
            "median": round(statistics.median(ordered), 1),
            "p90": round(ordered[max(0, int(0.9 * len(ordered)) - 1)], 1),
            "min": round(ordered[0], 1),
            "max": round(ordered[-1], 1),
        }

    summary = {
        "turn_seconds": spread(totals),
        "model_call_wait_seconds": spread(waits),
        "model_calls_per_turn": spread([float(count) for count in counts]),
    }
    if inputs:
        summary["context_tokens_per_turn"] = spread([float(value) for value in inputs])
        if cached and sum(inputs):
            summary["cache_hit_fraction"] = round(sum(cached) / sum(inputs), 2)
    return summary


def report(turns: list[dict], summary: dict) -> None:
    for turn in turns:
        started = turn["started"].strftime("%H:%M:%S")
        total = turn.get("total_seconds")
        head = f"{started}  {total:6.1f}s total" if total is not None else f"{started}  (incomplete)"
        if turn["setup"] is not None:
            head += f"   setup {turn['setup']:.1f}s"
        if turn["calls"]:
            head += f"   {len(turn['calls'])} model call(s)"
        print(head)
        for call in turn["calls"]:
            wait = f"{call['wait_seconds']:5.1f}s" if call["wait_seconds"] is not None else "    ?"
            marker = " *" if call["tool"] in TUTOR_TOOLS else "  "
            line = f"      +{call['at_seconds']:6.1f}s  waited {wait} ->{marker}{call['tool']}"
            usage = call.get("tokens") or {}
            if usage.get("input_tokens"):
                line += (f"   [in {usage['input_tokens']}"
                         f" cached {usage.get('cached_input_tokens', 0)}"
                         f" out {usage.get('output_tokens', 0)}]")
            print(line)
        tokens = turn["tokens"]
        if tokens.get("input_tokens"):
            window = turn.get("context_window")
            share = f" of {window} window" if window else ""
            print(f"      context {tokens['input_tokens']} tokens{share}, "
                  f"{tokens.get('cached_input_tokens', 0)} cached")

    print("\nsummary")
    for key, value in summary.items():
        if value is None:
            continue
        if isinstance(value, dict):
            print(f"  {key:26} n={value['n']:<4} median {value['median']:<7} p90 {value['p90']:<7} "
                  f"min {value['min']} max {value['max']}")
        else:
            print(f"  {key:26} {value}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--agent", default="calla", help="agent id whose sessions to read")
    parser.add_argument("--source", choices=["rollout", "store"], default="rollout",
                        help="rollout: per-model-call detail; store: turn totals over all history")
    parser.add_argument("--last", type=int, default=10, help="how many recent turns to report")
    parser.add_argument("--files", type=int, default=3, help="how many recent rollout files to read")
    parser.add_argument("--session", help="store source only: limit to one session id")
    parser.add_argument("--json", action="store_true", help="emit the turns and summary as JSON")
    arguments = parser.parse_args(argv)

    if arguments.source == "rollout":
        files = rollout_files(arguments.agent)
        if not files:
            print(f"No codex rollouts under {agent_directory(arguments.agent)}/agent/codex-home/sessions.\n"
                  f"If this agent does not use the codex runtime, use --source store.", file=sys.stderr)
            return 2
        turns = [turn for path in files[-arguments.files:] for turn in turns_from_rollout(path)]
    else:
        turns = turns_from_store(arguments.agent, arguments.session)
        if not turns:
            print(f"No sessions under {agent_directory(arguments.agent)}/sessions.", file=sys.stderr)
            return 2

    summary = summarise(turns)
    shown = turns[-arguments.last:] if arguments.last > 0 else turns

    if arguments.json:
        print(json.dumps({
            "agent": arguments.agent,
            "source": arguments.source,
            "turns": [{**turn, "started": turn["started"].isoformat()} for turn in shown],
            "summary": summary,
        }, indent=2))
        return 0

    report(shown, summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
