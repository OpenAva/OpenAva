---
name: arxiv-research
description: Find, triage, and synthesize academic papers using `arxiv_search` plus OpenAva web reading tools.
when_to_use: Use when the user wants to find papers, scan a research topic, compare recent work, or build a reading list from arXiv.
metadata:
  display_name: arXiv Research
  emoji: 📚
---

# arXiv Research

Use this skill for academic literature discovery and lightweight paper triage.

## Goal

Help the user:

- find relevant papers on a topic
- identify recent or highly relevant work
- compare a shortlist of papers
- read abstracts or full papers
- produce a concise literature summary or reading list

## Recommended Workflow

1. Use `arxiv_search` to find candidate papers.
2. Start with a small first pass:
   - `maxResults`: 5 to 10
   - `sort: relevance` for broad topic discovery
   - `sort: submittedDate` for recent work
3. Build a shortlist based on:
   - title relevance
   - abstract relevance
   - recency
   - author familiarity
   - category match
4. Use `web_fetch` on the arXiv abstract page when you need a deeper abstract-level read.
5. Use `web_fetch` on the PDF or HTML page only when the user needs full-paper understanding.
6. Summarize findings in a structured way:
   - shortlist of papers
   - what each paper contributes
   - key differences between papers
   - best next reads

## Recommended Output Shapes

When useful, present results as:

- **Shortlist**: 3 to 5 papers
- **Why it matters**: one sentence per paper
- **Best next reads**: ordered recommendation
- **Gaps or caveats**: unclear relevance, withdrawn paper, older source, or limited evidence

## Important Notes

- Prefer the returned versioned arXiv ID when precision matters.
- Check whether a paper is withdrawn before recommending it strongly.
- Do not claim to know full paper content unless you actually fetched and read it.
- Start broad, then narrow after seeing real results.
- If the user wants a literature review, compare papers against the user’s exact question rather than only summarizing each paper independently.

## Capability Mapping

- Discovery and metadata lookup: `arxiv_search`
- Read abstract page: `web_fetch`
- Read PDF or HTML page: `web_fetch`
- Optional follow-up synthesis: continue reasoning directly after the fetched content is available
