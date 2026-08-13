# Third-party review and notices

No third-party source code is vendored in this Phase 0 repository yet. The following projects informed the architecture or are intended as pinned adapters. Their licenses and notices must be preserved if code is later incorporated.

| Project | Reviewed commit | License | Current decision |
|---|---|---|---|
| OpenClaw | `dd1d151300c87810bedaaa153f94cd2e74f50c1d` | MIT | Brain runtime and plugin API |
| Peekaboo | `ae58d77640384c5c6973550c31bddf30c6b3c57a` | MIT | Prototype macOS observe/control/verify adapter |
| AXorcist | `dbafbe3a73a46f2d889fdbec53d550f8df919061` | MIT | Accessibility wrapper through Peekaboo |
| Tachikoma | `2ba00c869abb195209bd2a6633b0df6612ba17ea` | MIT | Optional future standalone model adapter |
| Blender MCP | `4460e97c04eaff06a1fa7497cb9223f0f8dd8e44` | MIT | Pattern study only; no arbitrary-code reuse |
| macapptree | `e1d8a5af3c708843d6c3d7831a5efcb1aa77cce8` | MIT | Future Pack Studio candidate |
| GUIrilla | `9e488b6b69a9e07d8ce7dfa366d6612537942961` | MIT | Sandboxed authoring/evaluation study |
| OpenClicky | `b0b4855ceb223ef0b0a57997cc0803cbd482f336` | MIT | UX/overlay study; coordinate protocol rejected |
| Cua | `3e2e1239617019f0a277bf515d818d3239ab141f` | MIT | Future VM/evaluation/cross-platform study |
| sqlite-vec | `04d28bd21773981e2d266bbf6aa4efbd011eb4f6` | MIT OR Apache-2.0 | Deferred optional vector index |
| MCP Swift SDK | `a0ae212ebf6eab5f754c3129608bc5557637e605` | licensing transition terms in upstream LICENSE | Optional interoperability adapter |

Explicit exclusions:

- AXSwift was reviewed but is currently avoided because AXorcist is active and already integrated with Peekaboo.
- screenpipe commit `23d0995bc28d2fd9f459b8f68345421a74ed044a` is under the Screenpipe Commercial License. Do not depend on it, copy it, or fork it into this open-source project.
