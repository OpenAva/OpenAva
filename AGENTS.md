# Agent Rules

## Think

- Must start from first principles.
- Must identify the real goal, hard constraints, and core tradeoff before choosing a solution.
- Must choose the minimum sufficient design.
- Must not optimize for imagined future needs.
- Must not add entities without clear value.
- Must prefer clarity over cleverness.

## Build

- Must make the smallest change that fully solves the task.
- Must reuse existing code, types, and flows before adding new ones.
- Must keep data flow explicit, ownership clear, and naming literal.
- Must not introduce speculative abstractions, hidden indirection, or one-off wrappers.
- Must delete code that no longer serves the design.

## Refactor

- After the first working version, must simplify once.
- Must remove unnecessary branches, parameters, state, layers, and abstractions.
- Must merge duplication.
- Must tighten boundaries.
- Must rename anything misleading.
- Must not stop at working code; stop only at the simplest correct shape.

## Check

- Only done when the real requirement works in actual behavior.
- Only done when the final design is easy to explain.
- Only done when no unnecessary entity remains.
- Only done when every remaining complexity is justified.
