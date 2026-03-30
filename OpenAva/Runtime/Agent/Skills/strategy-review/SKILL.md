---
name: strategy-review
description: Review a product or engineering plan strategically: challenge scope, compare alternatives, and sharpen direction and execution.
metadata:
  display_name: Strategy Review
  emoji: 🧭
---

# Strategy Review

Use this skill when the user asks things like:

- Think bigger.
- Rethink this plan.
- Is this ambitious enough?
- Hold scope but review it hard.
- Cut this down to the minimum viable version.

This is a strategic review skill for plans, proposals, and feature direction. It is not an implementation skill.

## How To Use This Skill

- Treat this skill as a review framework, not a fixed script.
- Ground recommendations in the current product, codebase, and constraints when that context is available.
- If only a written plan exists, keep the review useful by focusing on scope, tradeoffs, risks, and decision quality.
- Make scope changes explicit: separate baseline scope, optional expansion, and out-of-scope work.

## Core Mindset

- Challenge the premise, not just the details.
- Optimize for real user and business outcomes, not proxy work.
- Prefer complete thinking over shallow shortcuts.
- Keep scope changes explicit; never silently expand or shrink the plan.
- Bias toward simple systems with strong tests, clear ownership, and visible failure modes.

## Review Modes

Pick one mode before deep review. If the user already implied a mode, follow it.

### 1. Scope Expansion

Use when the user wants the boldest version.

- Describe the 10x version.
- Surface adjacent improvements that would make the feature noticeably better.
- Recommend expansions when they materially improve product quality or leverage.
- Keep each expansion explicit so the user can opt in.

### 2. Selective Expansion

Use when the current scope is the baseline but the user wants optional upgrades.

- Review the current plan rigorously.
- Surface a small set of high-value expansion opportunities.
- Present them as optional additions, not assumptions.

### 3. Hold Scope

Use when the user wants maximum rigor without changing scope.

- Do not add new product surface area.
- Focus on architecture, edge cases, errors, tests, observability, and rollout risk.

### 4. Scope Reduction

Use when the current plan is overbuilt or unclear.

- Define the smallest version that still creates real value.
- Separate must-have work from follow-up work.
- Remove complexity that does not support the core outcome.

## Default Workflow

### Step 1. Reframe The Problem

State:

- What problem the plan claims to solve.
- What outcome the user probably actually wants.
- What happens if nothing changes.

If the plan is solving a proxy problem, say so directly.

### Step 2. Audit Existing Leverage

Check what already exists before recommending new work.

- Existing code paths
- Reusable UI or infrastructure
- Similar flows already in the app
- Known constraints from the current architecture

Call out when the plan is rebuilding something that should be reused.

### Step 3. Compare Approaches

Produce at least 2 approaches when the work is non-trivial:

- Minimal approach: smallest diff, fastest path.
- Recommended approach: best balance of product quality, complexity, and future leverage.
- Ideal architecture: include only when meaningfully different.

For each approach, include:

- Summary
- Effort: S, M, L, or XL
- Risk: Low, Medium, or High
- Pros
- Cons
- What existing code or patterns it reuses

Then make one recommendation.

### Step 4. Review The Plan

Review the plan through these lenses:

1. Architecture
2. Error handling and rescue paths
3. Security and data boundaries
4. Interaction and edge cases
5. Code organization and complexity
6. Test coverage and failure-path testing
7. Performance risks
8. Observability and debugging
9. Deployment and rollback
10. Long-term trajectory

If the plan has user-facing UI scope, also review:

11. Design and UX clarity

### Step 5. Close With A Decision-Oriented Summary

End with:

- Recommended direction
- Critical gaps
- Explicitly out-of-scope items
- Open decisions that still need user input
- Suggested next step

## What Good Output Looks Like

Use direct, high-signal language. Prefer concrete findings over generic praise.

When useful, structure the response like this:

### Verdict

- One short paragraph on whether the plan is directionally right.

### What Already Exists

- Existing code or patterns the plan should reuse.

### Approach Options

- Approach A
- Approach B
- Approach C if needed

### Findings

- Critical gaps
- Warnings
- Strong parts of the plan

### Recommended Scope

- In scope
- Not in scope
- Follow-up work

### Next Decisions

- Questions that materially change scope, architecture, or risk

## Review Standards

### Architecture

- Prefer fewer moving parts.
- Flag plans that add new abstractions without clear payoff.
- Check whether the design fits current app patterns instead of introducing a parallel system.

### Error Handling

- Every important failure should have a visible outcome.
- Name likely failure modes instead of saying "handle errors".
- Call out silent failure paths.

### Security

- Check permissions, data exposure, input validation, and secret handling.
- Flag any new attack surface or trust boundary.

### UX And Edge Cases

- Review loading, empty, error, partial, retry, and cancellation states.
- Consider first-time use, stale state, duplicate actions, and interrupted flows.

### Testing

- Ask what test would make this safe to ship.
- Cover happy path, failure path, and edge cases.
- Prefer concrete missing tests over vague "add more coverage" advice.

### Observability

- New code paths should be debuggable.
- Recommend logs, metrics, or tracing where failures would otherwise be opaque.

### Rollout

- Check migration safety, partial rollout risk, feature flags, and rollback posture.

### Long-Term Fit

- Judge whether the plan helps or hurts the app 6 to 12 months from now.
- Call out debt, path dependence, and knowledge concentration.

## Interaction Rules

- Ask questions only when the answer changes scope, architecture, or priority.
- Ask one focused question at a time.
- When offering options, recommend one and explain why.
- Do not invent required rituals, logs, dashboards, or documents unless they are clearly useful in this repo.
- Keep the review proportional: a small feature should not trigger a giant process document.

## Anti-Patterns

Avoid these behaviors:

- Turning a simple review into a giant compliance checklist.
- Requiring external tools or home-directory files.
- Expanding scope without explicit user approval.
- Recommending new infrastructure before checking what the app already has.
- Praising a plan without naming concrete risks.
- Suggesting implementation details that do not fit the current codebase.

## Final Rule

Be opinionated, but stay practical.

The goal is not to roleplay authority. The goal is to help the user make a sharper product and engineering decision.
