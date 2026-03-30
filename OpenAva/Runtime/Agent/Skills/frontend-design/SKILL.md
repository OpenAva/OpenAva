---
name: frontend-design
description: Build distinctive, production-grade frontend interfaces with strong visual identity using compile-free native HTML/CSS/JS by default.
metadata:
  display_name: Frontend Design
  emoji: 🎨
---

# Frontend Design

Use this skill when the user asks to build or beautify any web UI, such as:

- Websites, landing pages, marketing pages
- Dashboards and data-heavy interfaces
- Compile-free web pages and interactive UI
- HTML/CSS layouts, interactive prototypes, posters, microsites

This is a design-and-implementation skill. It should output real working frontend code, not only visual ideas.

## Runtime Constraint (Generic)

This skill is framework-agnostic and compile-free by default. Therefore:

- Prefer native **HTML + CSS + vanilla JavaScript**
- Avoid framework/toolchain dependencies that require compiling (React/Vue/Svelte, bundlers, npm build steps) unless the user explicitly requests them
- Deliver code that can run by opening the HTML directly
- Prefer self-contained deliverables (single HTML file with embedded CSS/JS) unless multi-file structure is explicitly needed

## Mission

Create frontend work that is:

- Production-grade and functional
- Visually distinctive and memorable
- Cohesive under one clear aesthetic direction
- Refined in typography, color, motion, spacing, and details

Avoid generic "AI template" output at all costs.

## Core Workflow

### 1) Understand Context Before Coding

Clarify:

- **Purpose**: what the UI needs to achieve
- **Audience**: who will use it and in what setting
- **Constraints**: small-screen-first responsiveness, performance, accessibility, and compile-free delivery limits
- **Differentiator**: the one impression users should remember

### 2) Commit to One Bold Aesthetic Direction

Pick a strong style and execute it consistently. Examples:

- Brutally minimal
- Editorial / magazine
- Retro-futuristic
- Industrial / utilitarian
- Playful / toy-like
- Luxury / refined
- Organic / natural
- Brutalist / raw

The rule is intentionality: both maximalism and minimalism are valid when executed with precision.

### 3) Implement Real Code

Deliver complete, runnable code in native HTML/CSS/JS by default, optimized for direct execution without build tooling.

When building compile-free UI:

- Keep structure semantic and accessible
- Centralize visual tokens with CSS variables
- Use lightweight vanilla JS modules/functions for interactions
- Ensure interactions are robust across touch, keyboard, and pointer inputs

## Aesthetic Execution Standards

### Typography

- Use characterful, context-appropriate type choices
- Avoid overused defaults (Arial, Roboto, Inter, system-only stacks)
- Pair expressive display fonts with readable body fonts
- Build hierarchy with weight, size, rhythm, and line length

### Color & Theme

- Commit to a deliberate palette with clear dominant and accent colors
- Use CSS variables for consistency
- Avoid timid, evenly distributed colors with no emphasis

### Motion

- Add meaningful animation to support hierarchy and delight
- Prioritize one high-impact orchestrated moment over random micro-animations
- Use staggered entrances, hover responses, and scroll-triggered reveals where appropriate
- Prefer CSS-based motion and minimal JS orchestration; keep animations smooth across devices

### Spatial Composition

- Use layout intentionally: asymmetry, overlap, broken-grid moments, or disciplined restraint
- Control density with purposeful negative space
- Ensure visual flow guides attention to primary actions

### Backgrounds & Surface Details

- Build atmosphere and depth (not flat defaults)
- Use gradient meshes, subtle textures/noise, geometric patterns, layered transparency, and dramatic shadows when fitting the concept
- Keep decorative details coherent with the chosen style

## Anti-Generic Rules (Must Follow)

Never default to:

- Predictable SaaS template layouts without context
- Cliche purple-on-white gradient aesthetics
- Repetitive component patterns with no visual personality
- Same font/color choices across unrelated tasks

Every generation should feel intentionally designed for that specific product context.

## Complexity Matching Rule

Match implementation depth to the concept:

- Maximalist direction -> richer code, layered effects, stronger motion system
- Minimal/refined direction -> restraint, precision spacing, subtle but deliberate details

Do not under-implement the chosen vision.

## Output Expectations

When returning results, include:

1. **Design Direction**: one short paragraph describing the chosen visual concept
2. **Implementation**: complete compile-free code (default: one runnable HTML file with embedded CSS/JS)
3. **Notes**: key decisions on typography, color, motion, and responsiveness

If a framework is explicitly requested by the user, follow that request. Otherwise keep implementation native and build-free.

If the user provides explicit brand rules, follow them first while preserving design quality.

## Final Principle

Think like a frontend designer-engineer, not a template generator.

The goal is to ship UI that works in production and is hard to forget.
