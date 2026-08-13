# Calla macOS node

`./scripts/setup-macos.sh --install` installs the complete private Mac side:

- `com.calla.tutor-host`, the native Swift menu-bar TutorHost;
- `com.calla.openclaw-node-host`, the `tutor` node-role plugin; and
- a tailnet-only WSS connection through the configured Tailscale HTTPS proxy.

No Gateway token or manually copied node ID is needed.
The server-side enroller binds the first pending node named `Calla Mac`.

The native host listens only on
`~/Library/Application Support/CallaTutor/tutor-host.sock`, with its
directory mode `0700` and socket mode `0600`. Protocol v2 handles semantic
observations, an explicitly requested in-memory JPEG of only the focused
allowlisted window, screenshot-driven guiding and narration, pack-authored local
overlays, point-only visual search priors, local approval, and fresh detector
verification. No capture is written to disk.

## The mark in the menu bar

Its colour is the status, so the state is legible without opening anything:

| | |
| --- | --- |
| green | ready to teach |
| blue | a lesson is running |
| orange | working on it, or a permission is missing |
| red | stuck — it has stopped getting anywhere |
| grey | teaching is paused |

Orange and red are deliberately different. A reconnect that resolves in a second
should not look like a failure, and "Reconnecting…" that never resolves is a lie
the learner has no way to see through, so after thirty seconds the status says
it cannot reach Calla and names what is likely in the way.

It is drawn as a tinted, non-template image on purpose. A template image is
recoloured by the system to match the menu bar, which is right for a plain icon
and exactly wrong when the colour is the message.

When reaching the Gateway needs a Tailscale approval, the link appears in the
menu with a button that opens it. The sender is the only thing that ever sees
that URL, and it is useless in a log nobody is tailing.

## Settings

The menu bar is where this Mac's owner sees and changes what Calla may do.
Everything there used to be a constant in the source:

- **Whether Calla is actually reachable.** The host never talks to the Gateway
  itself — the node agent holds that WebSocket — so the menu reports what that
  agent last logged about its connection, names the Gateway it reached, and
  shows when Calla last sent this Mac anything. Without it, a lesson that never
  starts and a lesson nobody asked for look identical from here.

- **Applications Calla may look at.** A lesson names the application it is
  teaching, but the effective allowlist is the intersection with this list, so a
  lesson can narrow the owner's choice and never widen it. "Allow <frontmost
  app>" adds whatever is in front, so no bundle identifier has to be typed.
- **Capture detail** — the long edge of the window image a lesson sends. Less
  detail keeps more of the screen unreadable off this Mac; more helps the model
  read small labels.
- **Pointer size**, **tooltip opacity**, **fade the pointer near mine** —
  Calla's pointer thins out as the owner's own pointer approaches it — and
  **show the status capsule**. The tooltip defaults to 92% opacity: enough to
  leave its context visible, while keeping the instruction readable.
- **Reset**, which puts every choice including the allowlist back to the
  shipped default, and **Logs**, which opens the node agent's log directory.
- **Screen Recording status**, with a button to the right pane in System
  Settings, so a missing grant is visible here rather than only inside a failed
  tool call.

Scoping the overlay to the application being taught is deliberately not a
setting. Calla annotating a window it is not teaching is a bug, not a taste.

## Permissions

Screen Recording is the only permission the default teaching path needs; it is
what lets the host capture the one focused window. TutorHost requests it at
launch and, if a Settings confirmation is needed, opens the exact Screen &
System Audio Recording pane from the menu so the owner can approve it there.
Accessibility is needed only for the pack-authored path, which resolves a
descriptor to a real control and can request approval to click it. Guiding and
narrating touch neither the Accessibility tree nor the mouse, so TutorHost
asks for Accessibility only when an owner-approved action reaches that
boundary; it then opens the exact Accessibility pane.

Both grants attach to `Calla TutorHost.app`, which `scripts/build-tutor-host-app.sh`
builds and installs. The overlay renderer ships nested at
`Contents/Helpers/CallaOverlayHelper.app` because AppKit panels only composite
from a separate application of their own.

## Shortcuts

Answering Calla never needs the mouse, and the tooltip is a poor click target
because it moves out from under your pointer:

| | |
| --- | --- |
| `⌥⌘⏎` | Did it — look again and point at the next step |
| `⌥⌘/` | Ask a question, typed into the tooltip |
| `⌥⌘.` | Stop the lesson |

These are Carbon hot keys rather than a global `NSEvent` monitor, which is what
keeps them working without an Accessibility grant.

A system-wide hot key outranks the application underneath it, so Calla claims
these three only while a lesson is on screen and gives them back the moment it
ends. A collision can therefore last as long as a lesson and no longer, rather
than taking three combinations away from every program on the Mac for good. If
another application already holds one when a lesson starts, Calla says so
instead of leaving a button that looks live and does nothing.

## Overlay scope

The cursor and tooltip are placed against the taught window — the tooltip sits
inside its bounds, and the pointer is clamped to it — so Calla never annotates
something it is not teaching.

They do not disappear when you look elsewhere. A lesson that vanished every time
the learner checked something had to be found again, so the step stays on screen
until the lesson ends or teaching is switched off in the menu bar.

The pointer never fades or moves out of the way; it is the thing being followed,
and it marks the spot even when the words are gone. Tooltip opacity is an owner
setting, and the tooltip still hides completely while your own pointer is over
it; it returns at the chosen opacity the moment you move away.

Two other answers were tried and are worse. Stepping to another corner detaches
the words from the arrow, because
a box this wide is only ever adjacent to the arrow at one of its own corners.
Collapsing it in place read as the tooltip vanishing anyway.

The hover test is made against the tooltip's anchor, never its live frame. That
distinction is what keeps the behaviour from chasing itself: earlier versions
tested against something the behaviour changed, so acting on the answer changed
the answer, and the tooltip shook or ping-ponged. Hiding moves and resizes
nothing, so it cannot recur.

A lesson knows its whole route — `tutor_plan` hands the Mac the steps up front —
but shows one at a time. The header counts "Step 2 of 5", which carries the same
shape in four words; listing every step made the tooltip tall enough to become
the thing in the way. The plan is provisional: the model re-issues it when the
screen turns out differently, so it never hardens into a script.

Waiting reads as progress rather than decoration: a dashed margin marches around
the pointer's own outline, and a bar travels across the tooltip. A question asked
from Raycast tells the Mac before the request leaves, so the wait starts
immediately instead of when the answer lands.

**Only over the app being taught** in Options scopes the overlay to the taught
window. It is off by default: scoping kept making lessons vanish while the
learner was working, and a lesson you have to go looking for is worse than one
that sits over a neighbouring window.

Starting and stopping sit next to the status in the menu bar: **Teach me…**
when no lesson is running, **Find it** and **Stop** when one is. Stop is
enforced here rather than asked of the model — a turn already in flight would
otherwise come back and put one more instruction on a screen the learner has
finished with. Anything that draws is refused with `lesson_stopped` until an
observation starts the next lesson.

A step ends when the learner says so — **Did it**, or `⌥⌘↩` — not when the
pixels change. Calla then says it is checking, looks at the window, and either
moves on or explains what is different and stays on the same step. Guessing from
the screen hurried people, and a step that looks finished often is not.

**Find it** in the menu bar pulses the pointer and tooltip where they already
are, for a lesson lost on a large display.
