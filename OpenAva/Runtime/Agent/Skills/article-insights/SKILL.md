---
name: article-insights
description: Analyze articles, PDFs, webpages, and long-form text into summaries, bullet takeaways, mind maps, action items, and bilingual quotes.
metadata:
  display_name: Article Insights
  emoji: 🔎
---

# Article Insights

Use this skill when the user asks things like:

- Summarize this article, essay, report, or post.
- Extract the core arguments from this PDF or URL.
- Turn this content into a mind map.
- Give me the key takeaways and next actions.
- Pull the best quotes and translate them when needed.

This is a structured reading and synthesis skill for long-form content. It is optimized for article analysis, not casual copy editing.

## Primary Goals

- Normalize source content into Markdown before analysis.
- Extract core arguments, logical structure, key takeaways, and representative quotes.
- Adapt emphasis based on the user's requested topics, audience, and depth.
- Produce clear output in the user's requested language, with natural explanation instead of mechanical translation.

## Supported Inputs

Handle these source forms when the content is available in chat or can be obtained with tools:

- URL or webpage content
- PDF file path or extracted PDF text
- Markdown documents
- Plain long-form text

If the source is not yet accessible, obtain the content first instead of guessing.

## Working Rules

- Convert the source into a clean Markdown working copy before deep analysis.
- Read the full content before summarizing when the material is reasonably sized.
- Give extra weight to any user-provided `focus_topics`.
- Adjust tone and level of explanation to the requested `audience`.
- Follow the user's requested output language. If the user does not specify one, prefer the language used in the request.
- When the source language differs from the output language, explain the ideas naturally while keeping important original terms, concepts, and named entities when helpful.
- For quotes, include the original sentence and provide a translation when the user requests it or when cross-language reading would clearly help.

## Output Modes

Select the mode from `output_style`. Default to `bullets`.

### 1. `tldr`

- Write one compact summary of about 150 to 200 words or the equivalent concise length for the output language.
- Focus on the article's main claim, why it matters, and the final conclusion.

### 2. `bullets`

- Provide a structured bullet summary in the output language.
- Include major claims, supporting logic, and important evidence or examples.
- Use section headings when helpful.

### 3. `mindmap`

- Output a Markdown hierarchical list that mirrors the article's structure.
- Show chapter, theme, and sub-point relationships clearly.
- Respect `max_sections` when the source is broad or repetitive.

### 4. `actions`

- Produce 3 to 5 concrete next-step suggestions for the reader.
- Base actions on the article's actual conclusions, not generic advice.

## Default Analysis Frame

Unless the user asks for a narrower scope, cover these elements:

1. Core arguments: the 1 to 3 most important claims.
2. Logical structure: how the article builds and connects its points.
3. Key takeaways: the main conclusions, observations, or findings.
4. Golden quotes: representative lines that capture the argument or insight.

## Optional Parameters

Use these parameters when the user provides them. Do not explain the parameters back to the user unless asked.

- `output_style`: one of `tldr`, `bullets`, `mindmap`, `actions`. Default `bullets`.
- `quote_count`: preferred number of quotes. Default `5`.
- `focus_topics`: topics or keywords to prioritize.
- `audience`: target audience such as executives, junior developers, or product managers.
- `depth_mode`: `surface` or `deep`. Default `deep`.
- `max_sections`: maximum number of major sections to keep in a mind map.

## Recommended Workflow

1. Identify the source type and collect the full text.
2. Normalize the material into Markdown.
3. Determine requested output mode and optional parameters.
4. Read for thesis, structure, evidence, and conclusion.
5. Extract core arguments, key takeaways, and quotes.
6. Generate the final response in the requested format and language.

## Quality Bar

- Do not invent claims that are not supported by the source.
- Do not over-compress nuanced arguments into shallow slogans.
- When the source is ambiguous or incomplete, state the limitation briefly.
- Prefer interpretation and synthesis over sentence-by-sentence paraphrase.
- Keep terminology consistent across the full output.
