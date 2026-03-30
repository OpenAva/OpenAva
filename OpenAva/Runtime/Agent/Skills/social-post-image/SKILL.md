---
name: social-post-image
description: Convert long-form text into clean, readable multi-image cards for social platforms like Xiaohongshu and Twitter.
metadata:
  display_name: Social Post Image
  emoji: 🖼️
---

# Social Post Image

Use this skill when the user wants to turn text into social-ready images (text poster/cards), not text-to-image generation from prompts.

## What This Skill Does

- Splits long text into multiple pages automatically
- Keeps each page readable with clean typography and spacing
- Renders card-style visuals (notes-like by default)
- Produces output suitable for Xiaohongshu, Twitter/X, and other social sharing scenes

## Tool to Use

Call the local tool `text_to_social_images`.

Required parameter:

- `text`: full source text

Common optional parameters:

- `title`: card title displayed at top
- `theme`: `notes` | `dark`
- `width`: custom pixel width
- `aspectRatio`: e.g. `3:4`, `4:5`, `16:9`
- `maxPages`: max number of output images

## Workflow

1. Clean and lightly edit the user text for readability (fix obvious line-break issues only).
2. Pick theme:
   - `notes` for warm, minimal reading cards
   - `dark` for high-contrast style
3. Call `text_to_social_images` with tuned parameters.
4. Return the generated image paths/pages clearly.

## Guardrails

- Do not invent facts or rewrite meaning.
- Keep output concise and readable; avoid over-decoration.
- If text is too long for requested `maxPages`, tell user content was truncated and suggest increasing `maxPages`.
