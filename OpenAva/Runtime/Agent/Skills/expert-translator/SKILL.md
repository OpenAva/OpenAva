---
name: expert-translator
description: Translate text with high accuracy, native fluency, glossary consistency, and exact format preservation using a translate-reflect-refine workflow.
metadata:
  display_name: Expert Translator
  emoji: 🌐
---

# Expert Translator

Use this skill for high-quality translation tasks where accuracy, natural phrasing, style control, and format integrity all matter.

## Inputs

- `source_text`: The original text to translate.
- `target_language`: The destination language, such as `Chinese`, `English (US)`, or `English (UK)`.
- `style_and_tone`: The target style, such as `Academic`, `Business Professional`, `Casual and Humorous`, or `Literary and Elegant`.
- `glossary` (optional): A key-value map of terms that must be translated consistently.

## Workflow

1. Analyze the request and identify the target language, required tone, domain vocabulary, and any glossary constraints.
2. Produce an initial translation that stays fully faithful to the source text.
3. Review the draft against the source for accuracy, omissions, additions, fluency, terminology consistency, and style alignment.
4. Refine the translation so it reads like original writing in the target language while preserving the source meaning.
5. Return only the final polished translation unless the user explicitly asks for supporting notes.

## Translate Rules

- Preserve original formatting exactly, including Markdown, lists, tables, links, emphasis, LaTeX, code fences, and YAML frontmatter.
- Do not translate locked zones such as code blocks, inline code, URLs, and YAML frontmatter keys.
- Apply glossary terms exactly when they appear.
- Prefer semantic fidelity first, then improve phrasing during refinement.

## Review Checklist

- Accuracy: no mistranslations, omissions, or added meaning.
- Fluency: no awkward literal phrasing or translationese.
- Style: matches the requested audience and tone.
- Terminology: glossary usage is correct and consistent.
- Format integrity: all formatting and locked zones remain intact.

## Output Rules

- Default output is only the final translated text.
- Do not expose internal reasoning, step-by-step analysis, or review notes.
- If the user explicitly asks for glossary usage or a diff list, append a short clearly labeled section after the translation.

## Quality Bar

- The final translation should feel native, idiomatic, and stylistically aligned with the target language.
- Refinement may be bold, but it must remain faithful to the source intent.
