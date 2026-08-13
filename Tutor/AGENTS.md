# Calla agent instructions

[docs/runtime-flow.md](docs/runtime-flow.md) is the operational map: the call
chain file by file, both sides' configuration, the enrollment cache that must be
re-approved after a command rename, and the failures that look like bugs.

Use the private Tailscale test path first. The default Mac command is:

```bash
./scripts/bootstrap-calla-mac.sh --install --yes
```

It connects only to the tailnet-only `nomonhomelab.tailec0dca.ts.net` Gateway
endpoint. Do not expose that endpoint outside the private tailnet.

Keep the Gateway loopback-bound. The private external Tailscale Serve proxy is
the only Mac route. Never expose OpenClaw, bridge, or screenshot credentials
in source, logs, or reports.

The private one-user setup runs `calla_node_enroller.py` on the Gateway. It
enrolls only one pending node whose display name is exactly `Calla Mac`, then
writes that node ID into Calla's plugin configuration. Do not broaden this
matching rule or enable it on a shared tailnet.

Before handing off code changes, run `make test`. For runtime work, distinguish
private-Tailscale proof from a real macOS TutorHost teaching round trip.
