#!/usr/bin/env python3
"""Local Calla lesson UI.

Serves the compiled App Pack lesson and grades each step against live Blender
state read through the read-only bridge. No coordinates, no control - the
learner does the clicking, the bridge does the verifying.
"""
from __future__ import annotations

import json
import os
import sys
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))

from blender_bridge_probe import find_descriptor, probe  # noqa: E402

PACK = REPO / "build/packs/blender.otpack"
PORT = int(os.environ.get("CALLA_LESSON_UI_PORT", "8791"))


# ---------------------------------------------------------------- pack loading
def load_pack() -> dict:
    entities = {}
    with zipfile.ZipFile(PACK) as zf:
        for name in zf.namelist():
            if not name.endswith(".json"):
                continue
            try:
                blob = json.loads(zf.read(name))
            except json.JSONDecodeError:
                continue
            for item in blob if isinstance(blob, list) else [blob]:
                if isinstance(item, dict) and "id" in item and "kind" in item:
                    entities[item["id"]] = item
    return entities


ENTITIES = load_pack()
LESSON = next((e for e in ENTITIES.values() if e.get("kind") == "lesson"), None)
DETECTORS = {i: e for i, e in ENTITIES.items() if e.get("kind") == "detector"}


# ------------------------------------------------------------ detector engine
def dig(state: dict, path: str):
    node = state
    for part in path.split("."):
        if isinstance(node, dict):
            node = node.get(part)
        else:
            return None
    return node


def evaluate(detector_id: str, state: dict) -> bool | None:
    """Evaluate an authored detector against live bridge state."""
    det = DETECTORS.get(detector_id)
    if not det or not state:
        return None
    query = det.get("query") or {}
    value = dig(state, query.get("path", ""))
    if "equals" in query:
        return value == query["equals"]
    if "contains" in query:
        return isinstance(value, list) and query["contains"] in value
    if "any" in query:
        spec = query["any"]
        if not isinstance(value, list):
            return False
        return any(
            isinstance(item, dict) and all(item.get(k) == v for k, v in spec.items())
            for item in value
        )
    return None


def bridge_state() -> tuple[dict | None, str | None]:
    try:
        response = probe(find_descriptor(), "observe_state")
    except Exception as exc:  # noqa: BLE001
        return None, f"{type(exc).__name__}: {exc}"
    if not response.get("ok"):
        return None, json.dumps(response.get("error", "bridge error"))
    return response["result"], None


def snapshot() -> dict:
    state, error = bridge_state()
    steps = []
    for index, step in enumerate(LESSON.get("steps", []) if LESSON else []):
        detector_id = (step.get("success") or {}).get("detector")
        steps.append(
            {
                "id": step.get("id"),
                "instruction": step.get("instruction"),
                "hints": step.get("hints", []),
                "detector": detector_id,
                "detector_title": (DETECTORS.get(detector_id) or {}).get("title"),
                "done": evaluate(detector_id, state),
                "index": index,
            }
        )
    prereqs = []
    for pre in (LESSON or {}).get("prerequisites", []):
        did = pre.get("detector")
        prereqs.append(
            {
                "detector": did,
                "title": (DETECTORS.get(did) or {}).get("title", did),
                "ok": evaluate(did, state),
            }
        )
    assessment = (LESSON or {}).get("assessment") or {}
    concept = next((e for e in ENTITIES.values() if e.get("kind") == "concept"), {})
    active = (state or {}).get("active_object") or {}
    return {
        "error": error,
        "lesson": {
            "title": (LESSON or {}).get("title"),
            "objective": (LESSON or {}).get("objective"),
            "policy": (LESSON or {}).get("teaching_policy", {}),
            "checkpoint": ((LESSON or {}).get("checkpoint") or {}).get("explain"),
            "assessment_prompt": assessment.get("prompt"),
            "assessment_done": evaluate((assessment.get("pass") or {}).get("detector"), state),
        },
        "concept": {"title": concept.get("title"), "text": concept.get("text")},
        "prereqs": prereqs,
        "steps": steps,
        "live": {
            "mode": (state or {}).get("mode"),
            "object": active.get("name"),
            "type": active.get("type"),
            "modifiers": [m.get("type") for m in active.get("modifiers", [])],
            "properties_contexts": (state or {}).get("properties_contexts"),
            "blender": ((state or {}).get("blender") or {}).get("version_string"),
        },
    }


# --------------------------------------------------------------------- server
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence request logging
        pass

    def _send(self, code, body, content_type):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith("/api/state"):
            self._send(200, json.dumps(snapshot()), "application/json")
        elif self.path in ("/", "/index.html"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")


PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>Calla — Bevel lesson</title>
<style>
:root{--bg:#14161a;--panel:#1c1f26;--line:#2b303b;--ink:#e8eaf0;--dim:#9aa3b2;--accent:#ff9500;--ok:#3ddc84;--no:#4a5162}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
header{padding:18px 24px;border-bottom:1px solid var(--line);display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
h1{font-size:18px;margin:0;font-weight:650}
.sub{color:var(--dim);font-size:13px}
.wrap{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:20px;padding:20px 24px;align-items:start}
@media(max-width:900px){.wrap{grid-template-columns:1fr}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:16px}
.step{display:flex;gap:12px;padding:14px 0;border-bottom:1px solid var(--line)}
.step:last-child{border-bottom:0}
.dot{width:22px;height:22px;border-radius:50%;flex:0 0 22px;margin-top:2px;display:grid;place-items:center;font-size:12px;font-weight:700;background:var(--no);color:#0b0d10}
.dot.done{background:var(--ok)}
.instr{font-weight:600;margin-bottom:6px}
.hint{color:var(--dim);font-size:13px;margin-top:8px;padding-left:10px;border-left:2px solid var(--accent)}
button{background:#262b35;color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:6px 11px;font-size:13px;cursor:pointer}
button:hover{border-color:var(--accent)}
.det{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;color:var(--dim);margin-top:8px}
.badge{display:inline-block;font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--line);color:var(--dim)}
.badge.on{color:var(--ok);border-color:var(--ok)}
.badge.off{color:var(--accent);border-color:var(--accent)}
table{width:100%;border-collapse:collapse;font-size:13px}
td{padding:4px 0;color:var(--dim)}td.v{color:var(--ink);text-align:right;font-family:ui-monospace,Menlo,monospace;font-size:12px}
textarea{width:100%;min-height:220px;background:#12151a;color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:10px;font:13px/1.5 inherit;resize:vertical}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:0 0 10px}
.err{color:#ff6b6b;font-size:13px}
.ladder span{margin-right:6px}
.ladder .live{color:var(--ok)}.ladder .dead{color:#6b7280;text-decoration:line-through}
</style></head><body>
<header>
  <h1 id="title">Calla</h1>
  <span class="sub" id="sub"></span>
  <span class="sub" style="margin-left:auto" id="tick"></span>
</header>
<div class="wrap">
  <div>
    <div class="card" id="prereq-card"><h2>Prerequisites</h2><div id="prereqs"></div></div>
    <div class="card"><h2>Steps</h2><div id="steps"></div></div>
    <div class="card"><h2>Checkpoint</h2><div id="checkpoint" class="sub"></div>
      <div style="margin-top:14px"><h2>Assessment</h2><div id="assess"></div></div></div>
    <div class="card"><h2 id="concept-title">Concept</h2><div id="concept" class="sub"></div></div>
  </div>
  <div>
    <div class="card"><h2>Live Blender state</h2><table id="live"></table><div id="err" class="err"></div></div>
    <div class="card"><h2>Assistance ladder</h2><div class="ladder" id="ladder"></div>
      <div class="sub" style="margin-top:8px;font-size:12px">Blender draws its UI in OpenGL and exposes no Accessibility elements, so highlight/point/click cannot resolve a target. Explain and verify are real.</div></div>
    <div class="card"><h2>My notes</h2><textarea id="notes" placeholder="What surprised you? What do you want to re-check later?"></textarea>
      <div class="sub" id="saved" style="font-size:12px;margin-top:6px"></div></div>
  </div>
</div>
<script>
const revealed = {};
function esc(s){return (s??"").toString().replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function render(d){
  document.getElementById('title').textContent = d.lesson.title || 'Calla';
  document.getElementById('sub').textContent = d.live.blender ? ('Blender ' + d.live.blender) : '';
  document.getElementById('err').textContent = d.error || '';
  document.getElementById('prereqs').innerHTML = d.prereqs.map(p =>
    `<div style="margin:4px 0"><span class="badge ${p.ok?'on':'off'}">${p.ok?'PASS':'FAIL'}</span> ${esc(p.title)}</div>`).join('');
  document.getElementById('steps').innerHTML = d.steps.map(s => {
    const hints = (revealed[s.id]||0);
    const shown = s.hints.slice(0,hints).map(h =>
      `<div class="hint"><b>${esc(h.kind)}</b>: ${esc(h.text || h.target || '')}${h.kind!=='verbal'?' <span class="badge off">unavailable</span>':''}</div>`).join('');
    const more = hints < s.hints.length ? `<button onclick="reveal('${s.id}')">Need a hint (${s.hints.length-hints} left)</button>` : '';
    return `<div class="step"><div class="dot ${s.done?'done':''}">${s.done?'✓':s.index+1}</div>
      <div style="flex:1"><div class="instr">${esc(s.instruction)}</div>${shown}
      <div style="margin-top:8px">${more}</div>
      <div class="det">verified by ${esc(s.detector)} → ${s.done===null?'unknown':(s.done?'satisfied':'not yet')}</div></div></div>`;
  }).join('');
  document.getElementById('checkpoint').textContent = d.lesson.checkpoint || '';
  document.getElementById('assess').innerHTML =
    `<div><span class="badge ${d.lesson.assessment_done?'on':'off'}">${d.lesson.assessment_done?'PASS':'PENDING'}</span> ${esc(d.lesson.assessment_prompt)}</div>`;
  document.getElementById('concept-title').textContent = d.concept.title || 'Concept';
  document.getElementById('concept').textContent = d.concept.text || '';
  const L = d.live;
  document.getElementById('live').innerHTML = [
    ['mode', L.mode], ['active object', L.object], ['type', L.type],
    ['modifiers', (L.modifiers||[]).join(', ') || 'none'],
    ['properties tab', (L.properties_contexts||[]).join(', ')]
  ].map(([k,v])=>`<tr><td>${k}</td><td class="v">${esc(v)}</td></tr>`).join('');
  const ladder = (d.lesson.policy.escalation)||[];
  document.getElementById('ladder').innerHTML = ladder.map(r =>
    `<span class="${r==='explain'?'live':'dead'}">${esc(r)}</span>`).join(' → ');
  document.getElementById('tick').textContent = 'updated ' + new Date().toLocaleTimeString();
}
function reveal(id){revealed[id]=(revealed[id]||0)+1;poll()}
async function poll(){
  try{const r = await fetch('/api/state'); render(await r.json())}catch(e){document.getElementById('err').textContent = e}
}
const notes = document.getElementById('notes');
notes.value = localStorage.getItem('calla-notes')||'';
notes.addEventListener('input',()=>{localStorage.setItem('calla-notes',notes.value);
  document.getElementById('saved').textContent='saved '+new Date().toLocaleTimeString()});
poll(); setInterval(poll, 1500);
</script></body></html>
"""


if __name__ == "__main__":
    if LESSON is None:
        print("no lesson found in pack", file=sys.stderr)
        raise SystemExit(2)
    print(f"Calla lesson UI: http://127.0.0.1:{PORT}/  (lesson: {LESSON.get('title')})")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
