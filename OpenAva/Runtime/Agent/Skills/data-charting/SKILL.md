---
name: data-charting
description: Transform structured data into clear chart-ready markdown blocks for a chart-capable message renderer.
metadata:
  display_name: Data Charting
  emoji: 📊
---

# Data Charting

Use this skill when the user asks to:

- Visualize metrics, trends, distributions, or proportions.
- Turn tabular/JSON data into charts.
- Compare multiple series over time or categories.
- Show thresholds, ranges, or baseline rules in charts.

This skill outputs chart markdown for the **in-app message renderer** (the chat message list UI) using fenced code blocks:

````markdown
```chart
{ ...json... }
```
````

## Core Rules

- Always output valid JSON inside ` ```chart ` blocks.
- Keep numeric fields as numbers, not strings.
- Keep each chart focused on one analytical question.
- Prefer concise titles and meaningful series names.
- If data is missing or ambiguous, state assumptions briefly before the chart.

## Runtime Target

- Target renderer: any chat/message renderer that supports ` ```chart ` fenced blocks.
- Expected format: fenced code block with language tag `chart` and a JSON object.
- If unsure, still output the exact ` ```chart + JSON ` structure.

## Supported Chart Types

Set `kind` to one of:

- `line`
- `area`
- `bar`
- `point`
- `rule`
- `rectangle`
- `pie`

## JSON Schemas

### 1) `line` / `area` / `bar` / `point`

```json
{
  "kind": "line",
  "title": "Weekly Visits",
  "height": 240,
  "line": {
    "x": ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "series": [
      { "name": "PV", "y": [120, 180, 160, 220, 260] },
      { "name": "UV", "y": [80, 110, 105, 130, 150] }
    ]
  }
}
```

Notes:

- For `area`, replace `line` with `area`.
- For `bar`, replace `line` with `bar`.
- For `point`, replace `line` with `point`.
- Every `series[i].y.count` must equal `x.count`.

### 2) `pie`

```json
{
  "kind": "pie",
  "title": "Traffic Source Share",
  "height": 240,
  "pie": {
    "items": [
      { "name": "Organic", "value": 45 },
      { "name": "Ads", "value": 35 },
      { "name": "Referral", "value": 20 }
    ]
  }
}
```

### 3) `rule`

```json
{
  "kind": "rule",
  "title": "Alert Thresholds",
  "height": 220,
  "rule": {
    "yValues": [100, 180, 250]
  }
}
```

### 4) `rectangle`

```json
{
  "kind": "rectangle",
  "title": "Value Ranges by Period",
  "height": 260,
  "rectangle": {
    "items": [
      {
        "label": "Stable Zone",
        "xStart": "Q1",
        "xEnd": "Q2",
        "yStart": 80,
        "yEnd": 140
      },
      {
        "label": "Target Zone",
        "xStart": "Q3",
        "xEnd": "Q4",
        "yStart": 120,
        "yEnd": 200
      }
    ]
  }
}
```

## Chart Selection Guide

- Use `line` for temporal trend comparison.
- Use `area` for cumulative/volume feeling over time.
- Use `bar` for category comparison.
- Use `point` for sparse observations or scatter-like snapshots.
- Use `pie` for composition with limited categories.
- Use `rule` to overlay thresholds/baselines.
- Use `rectangle` for interval/range highlighting.

## Workflow

1. Understand the question (trend, comparison, share, threshold, range).
2. Normalize source data into `x` + numeric values.
3. Pick the most suitable `kind`.
4. Generate one ` ```chart ` block per chart.
5. Optionally add 1-2 sentence insight after the chart.

## Quality Bar

- Do not fabricate data points.
- Do not output malformed JSON.
- Keep chart titles short and specific.
- Keep category labels human-readable.
- Prefer <= 8 categories in pie charts for readability.
