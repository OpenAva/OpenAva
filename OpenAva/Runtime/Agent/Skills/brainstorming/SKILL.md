---
name: brainstorming
description: Use this before creative work. Turn vague ideas into approved plans through key-question-first collaboration.
metadata:
  display_name: Brainstorming
  emoji: 💡
---

# Brainstorming Ideas Into Designs

Use this skill to turn raw ideas into clear, approved plans before execution.

## Hard Gate

Do NOT start execution actions until:

1. A concrete recommendation or plan has been presented
2. The user has approved next action

For very small, low-risk tasks, a concise recommendation is enough (full plan doc not required).

## Why This Exists

"Simple" tasks still fail due to hidden assumptions. Good brainstorming reduces wrong turns by asking fewer, better questions.

## Adaptive Depth Guidance

Adapt interaction depth by complexity and uncertainty:

- Low complexity: concise clarification, direct recommendation, one confirmation
- Medium complexity: brief alternatives and trade-offs
- High uncertainty: fuller plan details, written doc, and deeper self-review

Do not label modes explicitly with the user; adjust depth seamlessly.

## Workflow Checklist (Complete In Order)

1. Explore project context (relevant files, docs, recent changes)
2. Ask only high-impact clarifying questions
3. Generate options (count adapts to complexity) and rank by decision matrix
4. Give one-line recommendation first, then brief rationale
5. Confirm next action with the user
6. If uncertainty/impact is high, write plan doc and run deeper self-review
7. After approval, transition to execution

## Process Rules

### 1) Explore Context First

- Inspect existing context and patterns before proposing changes
- Keep scope realistic
- If request is too large, split into sub-projects and plan only the first one now

### 2) Clarify With Key Questions Only

- Ask questions only when missing information would materially change the plan
- Keep a strict question budget: default 0-3 total questions for the planning phase
- Prioritize purpose, hard constraints, and success criteria
- Prefer multiple-choice and ask one question per turn when clarification is needed
- Skip questions when a reasonable assumption is low risk; state the assumption and continue

#### Stop Asking Condition

Stop asking immediately when all three are clear enough:

1. Success definition
2. Hard constraints
3. Priority trade-off

If clear, move to options and recommendation.

#### Key Question Filter (Ask only if YES)

Before asking, check all items:

1. Is this decision blocking or likely to cause rework if guessed?
2. Can the answer be derived from existing code/docs/context?
3. Does the question remove a meaningful branch in solution design?

If any answer is NO, do not ask; make and record a reasonable assumption.

#### Preferred Question Order

When questions are needed, ask in this order:

1. Success definition (what outcome proves this is done)
2. Hard constraints (time, scope, tech, platform, forbidden changes)
3. Priority trade-off (speed vs quality, flexibility vs simplicity)

Avoid asking about implementation details too early.

### 3) Explore Alternatives

- Provide adaptive option count:
  - 1 option for obvious/low-risk tasks
  - 2 options for normal tasks
  - 3 options for high-uncertainty tasks
- Lead with recommendation and explain why
- Include risks and trade-offs briefly

#### Decision Matrix (Keep It Short)

Evaluate each option with four factors:

1. Impact (value to user/business)
2. Cost (time/complexity)
3. Risk (failure/regression uncertainty)
4. Reversibility (ease of rollback/change)

### 4) Present Plan Incrementally

Cover these areas (scale depth to complexity):

- Objective and success criteria
- Scope and non-goals
- Workflow / process steps
- Risks, dependencies, and edge cases
- Validation method (how to know it worked)

After each section, ask whether it looks correct before continuing.

For low-complexity requests, skip per-section confirmations and use one final confirmation.

## Planning Quality Principles

- Keep units focused and easy to reason about
- Define clear interfaces between units
- Avoid unrelated refactors
- Improve nearby structure only when it directly helps current goal
- Apply YAGNI ruthlessly

## Visual Companion Rule

If visual explanation is likely useful, offer this exact message as a standalone response:

"Some of what we're working on might be easier to explain if I can show it to you in a web browser. I can put together mockups, diagrams, comparisons, and other visuals as we go. This feature is still new and can be token-intensive. Want to try it? (Requires opening a local URL)"

Do not combine this offer with other content. Wait for user response before continuing.

Only offer this when the decision is strongly visual (layout, flow, visual hierarchy). Otherwise skip it.

## Documentation

When uncertainty or impact is high and a full plan is needed:

1. Write plan doc to `docs/YYYY-MM-DD-<topic>-plan.md`
2. Ensure the plan is clear, concise, and execution-ready

Suggested sections:

- Problem and goals
- Non-goals
- Constraints
- Proposed approach
- Alternatives considered
- Risks and mitigations
- Validation and acceptance criteria
- Rollout notes (if needed)

## Self-Review Loop (No Subagent)

Because subagents are not supported, run this internal review loop before asking user for final review:

1. Read the full plan end-to-end
2. Check for ambiguity, contradictions, and missing decisions
3. Check that trade-offs and boundaries are explicit
4. Check validation method is specific enough to execute
5. Revise and repeat up to 3 passes (use fewer passes for low complexity)

If still uncertain after 3 passes, surface the uncertainty to the user explicitly.

## User Review Gate

After self-review, ask:

"Plan written to `<path>`. Please review it and tell me whether you want any changes before execution."

If the user requests changes, update the plan and run self-review again.

## Transition After Approval

After user approves the plan:

- Start execution only after approval
- Keep execution strictly aligned with the approved plan

## Final Rule

Plan first, execute second.

The goal is not speed to first action; the goal is fewer wrong turns and higher-quality outcomes.

Ask less, decide better: only ask what changes the plan.

Always end brainstorming with one clear recommendation sentence.
