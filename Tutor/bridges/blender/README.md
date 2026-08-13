# Blender Tutor Bridge

This add-on exposes bounded read-only state to the local macOS TutorHost. It binds only to loopback, generates a new token at each launch, writes the connection descriptor with owner-only permissions, and schedules Blender API reads on Blender's main thread.

Allowed operations:

- `ping`
- `observe_state`
- `observe_layout`

There is no arbitrary Python, file, asset-download, telemetry, or mutation operation.

`observe_layout` reports where Blender has drawn each editor and region, in window
pixels from the window's bottom-left. Blender draws its whole interface itself, so
macOS Accessibility sees one opaque window and anything pointing at a panel inside it
is guessing; this is how the guess stops. No conversion happens here — the host knows
the window's rectangle in screen points and derives the scale from the two widths,
which is the only way to stay correct on a Retina display, on an external display, and
after the window moves.

Build the installable ZIP from the repository root:

```bash
make blender-addon
```

Install `build/blender/calla-tutor-blender-0.3.0.zip` through Blender's **Edit → Preferences → Add-ons → Install from Disk** flow, enable **Interface: Calla Tutor Bridge**, and verify the live add-on while Blender remains open:

```bash
python3 tools/blender_bridge_probe.py --operation ping
python3 tools/blender_bridge_probe.py --operation observe_state
python3 tools/blender_bridge_probe.py --operation observe_layout
```

The probe discovers the newest active descriptor in `~/Library/Caches/CallaTutor`, validates its owner-only permissions and loopback address, and never prints its session token.
