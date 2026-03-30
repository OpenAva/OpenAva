---
name: github-trending
description: Aggregate GitHub Trending and related signals for tracking hot projects, observing language and domain trends, scanning competitors, and making technology choices. Deliver actionable conclusions with evidence and risk assessment.
metadata:
  display_name: GitHub Trending
  emoji: 📈
---

# GitHub Trending Explorer

## Core Capabilities

- Fetch and organize trending repositories and developer signals from GitHub Trending.
- Perform structured comparisons of projects and deliver conclusions suitable for learning, benchmarking, and technology selection.

## Data Source Priority

1. **Primary: GitHub Trending**
   - `https://github.com/trending`
   - `https://github.com/trending/{language}`
   - `https://github.com/trending?since=daily|weekly|monthly`
2. **Secondary: GitHub API**
   - Used to supplement baseline metrics such as stars, activity, and creation date.
3. **Supplementary: Community Signals**
   - Used for cross-validation only, never as a sole basis for conclusions.

## Execution Flow

1. Define scope: time window, language or domain, and goal (tracking, competitive scan, or technology selection).
2. Fetch candidates: start with Trending, then supplement with verifiable metrics via the API.
3. Structured evaluation: compare side by side across growth, health, and adoption dimensions.
4. Deliver results: provide conclusions, evidence, risks, and recommended actions.

## Evaluation Framework (Concise)

### 1) Growth Signals

- Stars count and recent growth rate
- Forks and contributors changes

### 2) Health Signals

- Recent commit frequency
- Issue and PR activity and response patterns
- Documentation and license completeness

### 3) Adoption Signals

- Clarity of the problem being solved
- Onboarding cost and integration complexity
- Competitive differentiation and cost of switching

## Output Requirements

- Lead with conclusions, then evidence. Avoid stacking metrics without insight.
- Do not fabricate star growth, commit frequency, or community activity.
- Mark missing data explicitly as `unknown`.
- Label time-sensitive observations as "based on current fetch time".
- When the user goal is technology selection or production adoption, always include risks and alternatives.

## Default Output Template

```markdown
# GitHub Trending Brief - {date}

## Conclusion
{One-sentence conclusion: the most valuable direction right now and why}

## Top 5 Trending Projects
| Project | Language | Key Metrics | Why Selected | Risk |
|---------|----------|-------------|--------------|------|
| {name} | {lang} | {stars / delta} | {reason} | {risk_or_unknown} |

## Technology Selection Recommendations (optional)
- Recommended: {project}, because {why}
- Alternative: {alternative}, suitable for {scenario}
- Watch out: {risk}
```
