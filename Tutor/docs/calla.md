# Calla operator guide

The current, supported setup is the private one-user path in the repository
[README](../README.md): configure the Gateway on this device with
`./scripts/setup-calla-server.sh --install --yes`, then run
`./scripts/setup-macos.sh --install` on the Mac.

It uses a loopback-bound OpenClaw Gateway with no Gateway login, a private
Tailscale HTTPS proxy, automatic single-Mac enrollment, and the bundled native
TutorHost.
