# Course research prompt

Paste everything below the line into any capable LLM, replacing the two bracketed
values. It researches an application and returns a course outline. Paste that
outline into **Calla → Settings → Courses → Import**, where Calla turns it into a
real App Pack by resolving the parts that need the running application.

The division of labour matters and is the reason this prompt is shaped the way it
is. The LLM knows the application's documentation. It cannot see the application,
so it must never guess at anything only the running program can answer — that is
Calla's job, on the Mac, with the window in front of it.

---

You are writing a course that a screen tutor will teach by pointing at a live
application. The tutor sees the user's screen and moves a cursor to real controls;
you do not. Research the application and return **one YAML document** in the
format below, and nothing else — no commentary before or after.

**Application:** `[Blender 5.2]`
**What the course should teach:** `[the basics of modelling without destroying your mesh]`

## What you must not do

These are not style preferences. Each one produces a course that fails silently.

- **Never invent identifiers.** No Accessibility ids, no element names, no
  internal API names, no class names, no menu indices. If you write
  `blender.ui.properties.modifiers_tab`, it will match nothing.
- **Never give coordinates**, pixel positions, or screen fractions. You cannot
  see the screen, and the tutor refuses coordinates from a model on principle.
- **Never write a keyboard shortcut you have not verified** in the documentation
  for the exact version named above. A wrong shortcut teaches a wrong habit.
- **Do not describe the UI as if you can see it.** Say what a person would look
  for — "the wrench icon in the properties column on the right" — not where it is.

If you are unsure whether a control exists in this version, leave the step out
and say so in `uncertain:` at the end. An omission is recoverable; an invention
is taught as fact.

## Output format

```yaml
course:
  title: Modelling basics
  app: Blender
  app_versions: ">=5.2 <5.3"     # the versions you actually researched
  icon: cube.transparent          # an SF Symbol name that suits the subject
  summary: One sentence on what someone can do afterwards that they could not before.

sources:                          # every claim traceable; official docs first
  - title: Blender Manual — Modifiers
    url: https://docs.blender.org/manual/en/latest/modeling/modifiers/index.html
    retrieved: 2026-08-12

lessons:                          # teaching order; one idea per lesson
  - title: Add a non-destructive Bevel modifier
    objective:
      given: The state the learner starts in.
      behavior: What they will be able to do.
      criterion: How you would know they can do it.

    concepts:                     # the idea behind the clicking, in prose
      - title: Non-destructive modifiers
        text: >
          A modifier changes how a mesh is displayed and rendered without
          changing the underlying mesh, until it is applied.

    misconceptions:               # name the wrong belief, then correct it
      - belief: Adding a Bevel permanently changes the mesh immediately.
        correction: A modifier is non-destructive until it is applied.

    prerequisites:                # what must already be true, and what to say
      - requires: The active object is a mesh.
        say: This lesson needs a mesh selected — click the cube first.

    steps:                        # one instruction each; no step does two things
      - do: Open the Modifier Properties tab.
        look_for: The wrench icon in the vertical strip of property icons.
        done_when: The Modifier Properties panel is showing.
      - do: Choose Add Modifier and select Bevel.
        look_for: The Add Modifier button at the top of that panel.
        done_when: A Bevel modifier appears in the modifier stack.
        diagnose:                 # the wrong turns, and what to say about each
          - when: The active object has a Subdivision Surface modifier.
            say: That added a Subdivision Surface, not a Bevel. Remove it and choose Bevel.

    assessment:                   # same skill, no hints
      prompt: Add a Bevel modifier to another mesh without hints.
      done_when: The second mesh has a Bevel modifier.

    transfer:                     # the skill somewhere it is not identical
      prompt: >
        On a mesh that already has Subdivision Surface, add Bevel and place it
        before Subdivision Surface, and explain the choice.
      differs_by: The stack is not empty, so order has to be chosen and justified.
      done_when: Bevel sits before Subdivision Surface in the stack.

    retention:                    # later, from memory
      prompt: Explain what makes a Bevel modifier non-destructive, then add one.
      done_when: A fresh mesh has a Bevel modifier and the learner explains why.

uncertain:                        # omit if empty
  - Whether the Add Modifier menu is grouped by category in this exact version.
```

## The rules that make a course teachable

- **`done_when` is what a person sees**, never what an API returns. "The panel is
  showing" is checkable. "`context.object.modifiers` is non-empty" is not.
- **Write `diagnose` for the mistakes you expect.** A learner told only "not yet"
  cannot get less wrong. Each entry names a state they might be in instead —
  phrased the same way as a `done_when` — and what to say about it. The tutor
  checks these on the Mac and says the matching one the moment it becomes true,
  rather than waiting to be asked.
- **Write `prerequisites` for what the lesson assumes.** They are checked before
  the lesson opens, and the `say` is what the learner reads if one fails.
- **One instruction per step.** If a step contains "and", it is two steps.
- **One idea per lesson.** A lesson that teaches bevelling *and* the modifier
  stack teaches neither. Split it and order them.
- **Every lesson needs all four**: `assessment`, `transfer`, `retention`, and at
  least one misconception. A lesson without transfer teaches a sequence of clicks
  rather than a skill.
- **Transfer must genuinely differ.** `differs_by` says how; if you cannot fill it
  in, the transfer is a repeat of the assessment.
- **Order lessons so each one only needs what came before.** Prerequisites live in
  the ordering, not in prose.
- **Name the misconception, not only the correction.** Being told the wrong belief
  out loud is what makes the right one stick.
- **Prefer the fewest steps that still teach.** The tutor points at one thing at a
  time and the learner is doing each one; ten steps is a long lesson.

## What happens next

Calla takes this outline and fills in what only the Mac can know: which control
each `look_for` actually is, how each `done_when` is checked against the running
application, and where the cursor goes. Your `do`, `done_when` and prose are used
as written, so they are what the learner reads.

Matching is against controls Calla already ships for this application, and it is
deliberately strict: a `look_for` or `done_when` that fits two of them equally
well, or none, is reported on the review card with the phrase quoted, and its
lesson is left out rather than compiled against a guess. So describe controls the
way the application's own documentation names them — "the Add Modifier button",
"the wrench icon" — and if a lesson comes back unresolved, the fix is to say
which control you meant, not to make the wording vaguer.
