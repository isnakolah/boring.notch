# Ask Calla from the Mac it teaches

Calla runs on the machine it is teaching, which makes triggering it awkward:
anything you type into puts a different window in front of the one you want
taught. Raycast solves that shape better than a menu or a chat window — it
overlays whatever you are using and hands focus straight back when it closes.

## Install

1. Raycast → **Extensions** → **Script Commands** → **Add Directories**
2. Pick this directory (`integrations/raycast`)
3. Select a published course in Calla TutorHost, then use **Next step**

## What happens

```text
Raycast          "how do I add a bevel modifier"
  └─ ssh ──────► nomonhomelab: active published lesson only
                   the Gateway thinks, and calls Calla's tools
                     └─ the Mac observes the app you were last in,
                        points its cursor, and waits for you to act
```

The turn runs on the Gateway. This Mac has no provider credentials and is not
meant to have any, so nothing here can quietly fall back to thinking locally.

The lesson lands on the allowlisted application you were last using, not on
Raycast, so you do not have to arrange your windows before asking. The overlay
only draws while that application is in front — switch back to it and the
cursor is waiting.

## Requirements

- The application must be allowed in Calla's menu bar ("Calla may look at").
- Screen Recording granted to Calla TutorHost.
- SSH to the Gateway. Tailscale SSH mints a browser check per new connection, so
  the script keeps one persistent connection open; when the check does expire it
  prints the approval link instead of failing silently.

Set `CALLA_GATEWAY_SSH` if your Gateway is not at `isnakolah@nomonhomelab`.
