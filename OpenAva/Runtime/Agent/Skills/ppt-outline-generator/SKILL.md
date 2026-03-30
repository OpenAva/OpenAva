---
name: ppt-outline-generator
description: Use when the user wants to plan a presentation, turn notes or drafts into a slide outline, or structure a report, pitch, or review deck.
metadata:
  display_name: PPT Outline Generator
  emoji: 🗂️
---

# PPT Outline Generator

Use this skill to turn a topic, scattered notes, meeting minutes, or a rough draft into a clear PPT outline.

This skill focuses on deck planning, not final slide rendering.

## Use This Skill For

- Planning a full presentation from a single topic.
- Turning scattered notes, minutes, or long text into a clear outline.
- Structuring a report, pitch, review, or proposal deck.
- Defining the main conclusion and content focus for each slide.

## Boundaries

- Only produce the outline and page-level content design.
- Do not claim to generate a playable PPT or design file.
- Do not fabricate business metrics, internal numbers, or research findings.
- If evidence is missing, suggest what data should be collected.

## Defaults

- Language: match the user's language. If unclear, default to Simplified Chinese.
- Objective: `informational update`.
- Audience: `mixed`.
- Style: `consulting`.
- Length: 8 to 12 slides.
- Output: `markdown` only.

When defaults are used, show them under `Assumptions`.

## Inputs

Normalize the request into these fields:

- `topic`: required presentation topic.
- `objective`: the decision, update, or persuasion goal.
- `audience`: `management`, `business`, `engineering`, `mixed`, or `external`.
- `duration_or_pages`: talk duration or target slide count.
- `style`: `consulting`, `minimal_tech`, or `passionate_report`.
- `input_materials`: notes, draft copy, minutes, summaries, or source material.

If `topic` is missing, ask 1 to 3 short clarification questions before generating the outline.

If other fields are missing:

- Ask up to 3 focused questions if the answer would materially improve the outline.
- If the user asks for a generic outline without follow-up questions, proceed with defaults and state the assumptions clearly.

## Workflow

### 1. Define the Story

- Identify the user goal, likely audience, and expected decision or takeaway.
- If the source material is long, summarize it briefly before structuring.
- Pick a narrative that fits the use case.

### 2. Build the Structure

- State one top-level `Key Message` for the whole presentation in 1 to 2 full sentences.
- Break it into 3 to 5 first-level sections.
- Keep sections as MECE as possible: avoid repetition and cover the main dimensions.
- Prefer natural narrative flow unless the user explicitly wants a highlight-first story.

### 3. Model Each Slide

Each slide should include:

- `page_title`: an Action Title that states the conclusion directly.
- `key_message`: 1 to 3 sentences that explain the slide takeaway.
- `supporting_points`: 2 to 5 supporting bullets.
- `evidence`: optional evidence items or data collection suggestions.
- `visual_suggestion`: recommended chart or visual format with rationale.
- `notes`: optional speaker notes.

Use Action Titles consistently.

Good:

- `Generative AI has become a major lever for engineering efficiency`
- `Delivery delays are now concentrated in testing and release stages`

Avoid neutral titles such as:

- `Generative AI use cases`
- `Problem analysis`

### 4. Handle Evidence Carefully

When real data is unavailable, use a collection hint instead of a fabricated number, for example:

- `Data collection suggestion: measure release frequency and average build time over the past 12 months from the internal CI/CD system.`

### 5. Adapt the Style

Keep the structure stable across styles. Change tone, emphasis, and visual bias.

#### consulting

- Formal, structured, and decision-oriented language.
- Prefer structured argument and professional charts.

#### minimal_tech

- Shorter sentences and tighter slide density.
- Focus on key capabilities, metrics, and impact.

#### passionate_report

- More energetic and story-driven wording.
- Lead with wins, contrasts, and memorable highlights.

### 6. Render the Output

Render the result in Markdown only.

- Use `#` for the deck title.
- Use `##` for top-level sections.
- Use `###` for each slide title.
- Use bullets for `supporting_points`.
- Use short labeled lines for `Key Message`, `Evidence`, `Visual Suggestion`, and `Notes`.
- Use `---` between slides when it improves readability.

### 7. Self-Check Before Responding

Check the outline against this quality bar:

- The whole deck has one clear top-level key message.
- There are 3 to 5 first-level sections.
- Each slide focuses on one main conclusion.
- Titles are Action Titles, not topic labels.
- The section structure is MECE enough for the user goal.
- The selected style is reflected consistently.
- Missing evidence is marked as assumption or data-to-collect, not invented fact.

## Output Order

Always return a human-readable Markdown result.

- `Assumptions` if needed
- `Top-Level Key Message`
- section-by-section slide outline
- optional `Missing Information` or `Suggested Expansion Areas`

## Error Handling

- If the topic is missing, ask concise clarification questions first.
- If the request exceeds scope, explain the boundary and still provide the outline.
- If the user asks for conflicting goals such as `minimal` and `heavy detail on every slide`, call out the tension and provide a practical compromise.
- If the user asks for another output format, explain that this skill returns Markdown and then provide the Markdown outline.

## Final Rule

Prefer explicit assumptions over hidden guesses.

The goal is a PPT outline that is logically sharp, easy to continue editing, and safe to hand off to a human designer or another automation step.
