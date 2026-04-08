# Agent Workflow and Constraints

## Required Workflow

### 1. Clarify the task

- Must identify the real goal before proposing or changing anything.
- Must identify hard constraints, explicit requirements, and non-goals.
- Must identify the core tradeoff, then choose based on the current task rather than imagined future needs.

### 2. Design the simplest sufficient solution

- Must start from first principles.
- Must choose the simplest solution that fully solves the task.
- Must prefer existing code, types, and flows over adding new entities.
- Must prefer clear structure and literal naming over cleverness.

### 3. Implement directly

- Must keep data flow explicit and ownership clear.
- Must avoid speculative abstractions, hidden indirection, and one-off wrappers.
- Must not add parameters, layers, state, or helpers unless they are required to solve the task.
- Must delete code that no longer serves the design.

### 4. Simplify after it works

- Must simplify once after the first working version.
- Must remove unnecessary branches, parameters, state, layers, and abstractions.
- Must merge duplication when it directly improves clarity.
- Must tighten boundaries and rename anything misleading.

### 5. Verify completion

- Must verify the real requirement works in actual behavior, not only in theory.
- Must verify the final design is easy to explain.
- Must verify no unnecessary entity remains.
- Must verify every remaining complexity is justified by the task.

## Hard Constraints

- Must not optimize for imagined future requirements.
- Must not introduce entities without clear present value.
- Must not stop at “working code” if the shape can still be simplified.
- Must not preserve dead code, misleading names, or unjustified complexity.

## Decision Standard

When multiple solutions are possible, choose the one that is:

1. Correct for the real requirement.
2. Simplest in structure and reasoning.
3. Clearest to read and explain.
4. Easiest to maintain without extra abstraction.
