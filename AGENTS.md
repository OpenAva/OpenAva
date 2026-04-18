# Agent Operating Rules

Goal: complete the user's current requirement with the **lowest necessary complexity**, and make the result easy to verify and explain.

## Highest Priority (Hard Rules)

- **State the requirement before acting**: summarize the user-visible behavior change in 1 sentence. If uncertain, ask only the minimum necessary clarification.
- **Read before changing**: inspect the relevant files/types before editing, and make the smallest change that fits the existing structure.
- **Prefer existing flows**: if the requirement can be solved inside existing types/functions/flows, do not add a manager / wrapper / service / helper.
- **Do not design for the future**: do not solve hypothetical future needs; do not add extension points unless the current task clearly requires them.
- **Simplify after it works**: after the first working version, do one simplification pass to remove dead code, redundant branches, one-off parameters, and misleading names.
- **Verification is required**: validate the change using the most direct available method (tests / compile / direct path validation). “It should work” is not enough.

## Triggered Rules (When / Then)

- **When adding a new entity**: first prove that modifying the existing code cannot express the requirement cleanly. Then explain why the new entity is necessary, what it owns, and why editing the existing code was not enough.
- **When two solutions both work**: choose the one with fewer new concepts, fewer lines of code, and fewer indirection layers.
- **When a change touches multiple modules**: keep data flow explicit, with clear ownership of parameters, return values, and state. Avoid hidden global state or opaque cross-layer flow.
- **When fixing a bug**: state the reproduction condition or visible failure first, then make the smallest fix, then add a regression validation point.

## Anti-Patterns

- Adding a new abstraction only to avoid editing the existing code
- Adding a helper/wrapper used only once, unless it clearly improves readability and removes duplication
- Keeping dead branches or compatibility code “just in case”
- Skipping verification after changes

## Output Contract

- **Requirement in one sentence**: what visible behavior change the user asked for.
- **Smallest sufficient solution**: which files / key points changed, and why this is the smallest sufficient approach.
- **What was intentionally not done**: which new entities, abstractions, or future-oriented work were intentionally avoided.
- **How it was verified**: what tests, compilation, or direct checks were used.
- **No code in the final summary**: when summarizing conclusions, do not include code snippets or paste file contents unless the user explicitly asks for code.
