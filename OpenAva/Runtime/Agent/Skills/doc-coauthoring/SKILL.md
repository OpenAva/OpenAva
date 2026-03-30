---
name: doc-coauthoring
description: Guide users through a structured workflow for co-authoring documentation, from context collection to reader testing.
metadata:
  display_name: Doc Coauthoring
  emoji: 📝
---

# Doc Co-Authoring

Use this skill when the user wants to write structured documents, such as:

- Technical specs
- Proposals and decision docs
- PRD, RFC, or design docs
- Internal process docs and project write-ups

This is a collaborative writing workflow skill. It focuses on helping users produce documents that are understandable and actionable for real readers.

## Mission

Turn fuzzy internal context into a clear, reader-safe document by using a three-stage process:

1. Context Gathering
2. Refinement and Structure
3. Reader Testing

Do not jump directly to polished prose without first establishing context and structure.

## When To Offer This Skill

Offer this workflow when the user appears to be starting substantial documentation work.

Common triggers:

- "Write a doc"
- "Draft a proposal"
- "Create a spec"
- "Write an RFC"

Start by offering two modes:

- Structured workflow (recommended)
- Freeform writing

If the user declines structured workflow, continue in freeform mode.

## Workflow Overview

### Stage 1: Context Gathering

Goal: close the gap between what the user knows and what the assistant knows.

Ask for meta-context first:

1. What type of document is this?
2. Who is the primary audience?
3. What impact should this document create?
4. Is there a template to follow?
5. Any constraints, timeline pressure, or org context?

Tell the user they can respond in shorthand.

Then prompt for an info dump:

- Project background and history
- Rejected alternatives and why
- Architecture and dependencies
- Stakeholder concerns
- Risks, constraints, and deadlines

After substantial context is provided, ask 5 to 10 numbered clarifying questions.

Exit this stage only when trade-offs and edge cases can be discussed without re-explaining basics.

Transition question:

- "Do you want to add more context, or start drafting?"

### Stage 2: Refinement and Structure

Goal: build the document section by section through guided iteration.

For each section, follow this loop:

1. Ask 5 to 10 clarifying questions for that section.
2. Brainstorm 5 to 20 candidate points.
3. Ask user what to keep, remove, or merge.
4. Ask for missing points (gap check).
5. Draft the section.
6. Apply surgical edits from feedback.

If the user does not know which sections to use, propose 3 to 5 sections based on doc type.

Create a markdown scaffold with placeholders for all sections before filling details.

Important writing behavior:

- Avoid rewriting the whole document on every iteration.
- Edit only the relevant section.
- Learn and reuse the user's style preferences.
- Keep rationale concise and procedural.

Quality check within Stage 2:

- After multiple low-change iterations, ask what can be removed.
- At around 80% completion, reread full doc for flow, duplication, contradiction, and filler.

### Stage 3: Reader Testing

Goal: verify the document works for readers who do not share author context.

Process:

1. Generate 5 to 10 realistic reader questions.
2. Test whether answers are clear and accurate from the document alone.
3. Check ambiguity, hidden assumptions, and contradictions.
4. Feed failures back into targeted section edits.

Pass condition:

- Reader questions can be answered correctly.
- No major new ambiguity or contradiction appears.

## Interaction Rules

- Be direct, procedural, and high-signal.
- Ask questions only when they materially improve quality.
- Allow the user to skip stages and switch to freeform.
- If the user is frustrated, suggest a faster mode with fewer iterations.
- Keep user agency explicit in every transition.

## Output Expectations

During collaboration, keep outputs concise and actionable:

- Current stage and objective
- Numbered questions or options
- Drafted section content
- Clear next step

When the document is complete, finish with:

1. Final coherence check summary
2. Fact/link verification reminder
3. Optional final pass invitation

## Boundaries

- Do not fabricate facts, metrics, or organizational decisions.
- Do not force process overhead for small writing tasks.
- Do not confuse brainstorming notes with final document text.
- Do not assume readers share team-internal context unless explicitly documented.

## Final Rule

Prioritize reader comprehension over writing speed.

The goal is not just to finish a document. The goal is to produce one that survives first contact with real readers.
