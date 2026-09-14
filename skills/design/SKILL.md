---
name: design
description: Produce a concrete UI/UX design for one task before implementation. For user-facing tasks.
argument-hint: "<task-id>"
---

Write `intentpipe/tasks/<id>-<slug>/design.md` for task $ARGUMENTS. The implementer follows it literally: be concrete. Read every file the task's `Resources:` field lists first (images too); a referenced mockup is the starting point — interpret it, never override it.

Before speccing any component, inventory what exists (shared widget dirs, sibling screens): per component, name the existing widget to reuse or extend, or say why none fits. A new variant of an existing component is a recorded decision, never a default.

Cover, tersely:
1. Layout: components, hierarchy, spacing (ASCII sketch beats prose).
2. Visual language: colors (exact values), type scale, radii — consistent with the existing app (read it first).
3. States: empty, loading, error, success.
4. Interactions: what happens on click/hover/keyboard; motion only if it carries meaning.
5. One deliberate, fresh touch that lifts the design above the default, named explicitly. Spend it inside this design, never on a parallel variant of an existing component.

≤60 lines. No mood boards, no alternatives — decide.
