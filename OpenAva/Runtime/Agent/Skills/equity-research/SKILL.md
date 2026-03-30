---
name: equity-research
description: When a user asks for systematic research on a listed company or stock ticker, run an automated deep-dive that combines market data, earnings fundamentals, sentiment signals, and a multi-factor weighted framework to produce a structured research report.
metadata:
  display_name: Equity Research
  emoji: 📈
---

# Equity Research Analyst

## Inputs

- `target`: Company name or stock ticker (required)
- `market`: Trading venue (optional, e.g. `US` / `HK` / `CN`)
- `report_language`: Report language (optional, defaults to the user's language)

## Skill Goals

- Deliver a **traceable, explainable, and structured** deep research report.
- Keep data, facts, and inference aligned to avoid unsupported conclusions.
- Make uncertainty and risk boundaries explicit; avoid absolute claims.

## Core Execution Principles

- Stay goal-oriented: dynamically choose equivalent runtime capabilities instead of hard-binding to one fixed method.
- Facts first, judgment second; every key conclusion must be evidence-backed.
- Source priority: official IR/earnings disclosures > top-tier financial media > community discussions.
- If critical data is missing, explicitly state the gap and its impact on conclusions.
- Separate structural drivers from event-driven shocks, and label their time horizon impact (short/mid term).
- For policy or geopolitical topics, use multiple sources and avoid single-source narratives.

## Goal 1: Build a Reliable Data Baseline (Required)

You must collect and verify the following data (Yahoo Finance basis):

- Real-time/near real-time market snapshot: current price, daily % change, market cap.
- Core financial indicators: P/E ratio, EPS.
- Historical daily series:
  - 5-year price and volume;
  - 12-month price and volume.

Requirements:

- You must explicitly state: **market data may be delayed and is for reference only.**
- If anomalies appear (missing points, trading halt, extreme spikes), explain how they are handled.

## Goal 2: Deliver Fundamental Analysis from the Latest Earnings (Required)

Extract key information centered on the latest quarterly earnings, including:

- Revenue and YoY/QoQ trend;
- Net income and earnings quality;
- Performance by key business segments;
- Management guidance.

Output must include two sections:

- **Highlights**
- **Risks**

Source priority:

1. Company IR pages, earnings press releases, and earnings call materials;
2. Top financial media such as Bloomberg, Reuters, and Wallstreetcn.

## Goal 3: Complete 90-Day Market Sentiment Attribution (Required)

Cover three signal groups:

- Media/news: tone of major reports and analyses;
- Institutional ratings: Buy/Hold/Sell distribution, target-price range or average;
- Social discussion: key retail focus points from platforms like Xueqiu and Reddit.

You must also cover one macro-event overlay (required):

- Policy and geopolitical context: monetary/fiscal policy shifts, regulation changes, tariff/sanction/export-control developments, regional conflict risks, and their transmission path to valuation or earnings expectations.

You must provide:

- Sentiment attribution (key events/expectations driving the tone);
- Overall sentiment judgment (positive / neutral / negative).
- A confidence level for each sentiment conclusion (high / medium / low), with brief rationale.
- A catalyst timeline for the next 30-90 days (known events and unknown-risk placeholders).

## Goal 4: Produce an Explainable 6-12 Month Outlook (Required)

Use this fixed multi-factor weighted framework (weights must not change):

- Financial robustness: **40%**
- Industry track and moat: **25%**
- Management expectation and credibility: **15%**
- Market sentiment: **20%**

Requirements:

- Provide a 0-100 score and evidence summary for each factor;
- Provide the weighted total score and explain major positive/negative contributors;
- Forecast window is fixed: **2026-09-22 to 2027-03-22**;
- Output three scenario-based price ranges:
  - Bull
  - Base
  - Bear
- Do not use absolute language (e.g., "certain to rise/fall").
- Explicitly map policy/geopolitical assumptions in each scenario (what changes, what stays constant, why).

## Goal 5: Run an Omission Check for Hidden Drivers (Required)

Before finalizing conclusions, run a compact checklist and state whether each item is relevant (yes/no + one-line reason):

- Macro sensitivity: rates, inflation, FX, and commodity input costs;
- Policy/geopolitical sensitivity: sanctions, tariffs, export controls, data/security regulation;
- Supply-chain concentration: key supplier/customer dependency and substitution difficulty;
- Balance-sheet and refinancing risk: debt maturity wall, financing cost sensitivity;
- Ownership/liquidity structure: institutional concentration, short interest, unlock/insider selling schedule;
- Event calendar risk: earnings date, major product cycle, litigation or regulatory decision windows.

If any item is highly relevant but lacks data, include it in "Data Gaps and Impact" and reduce confidence in related conclusions.

## Output Requirements (Mandatory)

The report structure must follow this exact order:

1. Company Overview
2. Price Performance
3. Fundamental Analysis
4. Market Sentiment Analysis
5. Multi-Factor Weighted Analysis and Outlook
6. Hidden Driver Omission Check
7. Risk Notice and Disclaimer

Formatting requirements:

- Present core financial data in a structured form, preferably via tables or charts, so it is clear, comparable, and reviewable.
- Present factor scoring and weighted calculations in a traceable way, preferably via tables or charts, so readers can verify rationale and math.
- **Highlight** key conclusions, metric names, and critical data points (bold or equivalent emphasis).
- Provide at least two visualized information views:
  - 5-year price trend;
  - 12-month price plus volume.
- Add one structured "Catalyst and Risk Event Matrix" view, including at least: event, directionality, probability (low/medium/high), expected impact channel, and monitoring signal.
- Within runtime feasibility, prefer tables or charts while keeping output complete, readable, and verifiable.
- Do not generate TOC, references, acknowledgements, or unrelated sections.
- Deliver the report as one complete document in a single response.

## Recommended Capability Mapping (Non-Restrictive)

These are common mappings only. Replace dynamically based on runtime availability:

- Market and financial data: `yahoo_finance`
- News retrieval: `web_search`
- Page content extraction: `web_fetch` / `web_view_read`
- Long-form synthesis: `article-insights`
- Chart rendering: `data-charting`
- Copy refinement: `copy-clarifier`
- Counter-view challenge: `strategy-review`

## Fallback and Degradation Strategy

- If a unique ticker cannot be confirmed, list candidates first and withhold hard conclusions.
- If key earnings or rating data is missing, continue the report but add a dedicated "Data Gaps and Impact" section.
- If sources conflict, prioritize official disclosures and present conflicts side by side.
- If policy/geopolitical information is uncertain or contradictory, keep scenario analysis but downgrade confidence and explain trigger conditions for view changes.

## Compliance and Disclaimer (Must Appear at the End Verbatim)

The final report must end with the exact sentence below:

**本报告由 AI 生成，其分析和预测仅供参考，不构成任何投资建议。投资者据此操作，风险自负。**

## Quality Floor

- Do not fabricate data or sources.
- When key data is missing, clearly state the impact on conclusions.
- Separate facts from inference.
- Keep terminology consistent (EPS, P/E, Guidance, Market Cap).
