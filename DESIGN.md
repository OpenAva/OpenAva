# OpenAva Design Guidelines

OpenAva should feel warm, confident, restrained, and slightly editorial. Use these rules to keep the product visually consistent. If rules conflict, prioritize: **brand feel > readability > consistency > decoration**.

## 1. Core Rules

1. **Use warm neutrals by default.** Base surfaces should use Warm Cream (`#faf9f6`) and Oat (`#dedbd6`), not cool gray.
2. **Keep text high contrast.** Primary text and strong UI elements use Off Black (`#111111`).
3. **Use one accent color.** Brand Orange (`#ff5600`) is only for brand emphasis, AI-focused actions, and key highlights.
4. **Keep geometry sharp.** Buttons use 4px radius. Cards and containers use 8px radius.
5. **Keep headings editorial.** Headings use Saans with tight line-height and negative tracking.
6. **Create depth with borders, not shadows.** Prefer warm outlines and surface contrast over visible elevation.

## 2. Visual Tone

- **Backgrounds:** warm, calm, clean
- **Content:** clear hierarchy, moderate density, no visual noise
- **Interaction:** tactile and physical, not floaty

## 3. Color System

### Primary Colors

| Role | Value | Usage |
|------|------|------|
| Off Black | `#111111` | Primary text, dark button fills, strongest contrast |
| Pure White | `#ffffff` | Inverted text, white surfaces |
| Warm Cream | `#faf9f6` | Default background, card background, warm button surfaces |
| Brand Orange | `#ff5600` | Brand emphasis, AI primary actions, key focus states |
| Report Orange | `#fe4c02` | Data visualization orange |

### Warm Neutrals

| Role | Value | Usage |
|------|------|------|
| Black 80 | `#313130` | Strong secondary text |
| Black 60 | `#626260` | Secondary information |
| Black 50 | `#7b7b78` | Muted text |
| Content Tertiary | `#9c9fa5` | Tertiary text |
| Oat Border | `#dedbd6` | Default border color |
| Warm Sand | `#d3cec6` | Light separators, subtle surface shifts |

### Data Visualization Palette

Use these only for charts, data markers, or status graphics — not as general UI accents.

- Report Blue `#65b5ff`
- Report Green `#0bdf50`
- Report Red `#c41c1c`
- Report Pink `#ff2067`
- Report Lime `#b3e01c`
- Green `#00da00`
- Deep Blue `#0007cb`

## 4. Typography

### Font Families

- **Primary:** `Saans`, `Saans Fallback, ui-sans-serif, system-ui`
- **Serif:** `Serrif`, `Serrif Fallback, ui-serif, Georgia`
- **Monospace:** `SaansMono`, `SaansMono Fallback, ui-monospace`
- **UI emphasis:** `MediumLL` / `LLMedium`, `system-ui, -apple-system`

### Usage Rules

- Use **Saans** for all headings. Keep line-height near `1.00` and preserve negative tracking.
- Use **Saans** for body copy and general UI.
- Use **Serrif** only for editorial moments or long-form emphasis.
- Use **SaansMono** for code, technical labels, or uppercase utility text.
- Use **LLMedium** only when a bold UI emphasis is needed.

### Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing |
|------|------|------|--------|-------------|----------------|
| Display Hero | Saans | 80px | 400 | 1.00 | -2.4px |
| Section Heading | Saans | 54px | 400 | 1.00 | -1.6px |
| Sub-heading | Saans | 40px | 400 | 1.00 | -1.2px |
| Card Title | Saans | 32px | 400 | 1.00 | -0.96px |
| Feature Title | Saans | 24px | 400 | 1.00 | -0.48px |
| Body Emphasis | Saans | 20px | 400 | 0.95 | -0.2px |
| Nav / UI | Saans | 18px | 400 | 1.00 | normal |
| Body | Saans | 16px | 400 | 1.50 | normal |
| Body Light | Saans | 14px | 300 | 1.40 | normal |
| Button | Saans | 16px / 14px | 400 | 1.50 / 1.43 | normal |
| Button Bold | LLMedium | 16px | 700 | 1.20 | 0.16px |
| Serif Body | Serrif | 16px | 300 | 1.40 | -0.16px |
| Mono Label | SaansMono | 12px | 400–500 | 1.00–1.30 | 0.6px–1.2px uppercase |

## 5. Component Rules

### Buttons

#### Primary Dark
- Background: `#111111`
- Text: `#ffffff`
- Radius: `4px`
- Horizontal padding: `14px`
- Hover: white background, dark text, `scale(1.1)`
- Active: green background `#2c6415`, `scale(0.85)`

#### Outlined
- Background: transparent
- Text: `#111111`
- Border: `1px solid #111111`
- Radius: `4px`
- Hover / Active: same scale behavior as Primary Dark

#### Warm Card Button
- Background: `#faf9f6`
- Text: `#111111`
- Padding: `16px`
- Border: `1px solid` warm low-contrast outline
- Use for settings rows, card actions, and secondary entry points

### Cards and Containers

- Background: `#faf9f6`
- Border: `1px solid #dedbd6`
- Radius: `8px`
- No visible shadow by default

### Navigation

- Use Saans 16px for standard navigation text
- Keep surfaces white or lightly warm
- Small nav buttons should stay within `4px–6px` radius
- Use Brand Orange only for AI-related focus or important active states

## 6. Layout

### Spacing Scale

Use only these spacing values: `8, 10, 12, 14, 16, 20, 24, 32, 40, 48, 60, 64, 80, 96`

### Radius Scale

- Buttons: `4px`
- Nav items: `6px`
- Cards / containers: `8px`

## 7. Motion and Depth

- Clickable elements use physical scale feedback: Hover `scale(1.1)`, Active `scale(0.85)`
- Motion should feel tactile, not airy
- Use borders, surface contrast, and spacing for hierarchy
- When opacity is needed, prefer oklab-based color handling to avoid muddy grays

## 8. Responsive Breakpoints

Use these breakpoints: `425px`, `530px`, `600px`, `640px`, `768px`, `896px`

## 9. Do / Don't

### Do
- Use warm neutral backgrounds and warm borders
- Keep negative tracking on every heading
- Reserve Brand Orange for true brand or AI emphasis
- Keep buttons sharp, simple, and clearly interactive
- Build hierarchy with borders and surface shifts

### Don't
- Don't round buttons beyond 4px
- Don't use Brand Orange as a decorative accent everywhere
- Don't use cool gray borders
- Don't remove the editorial feel from headings
- Don't rely on heavy shadows

## 10. Quick Reference

### Quick Color Reference
- Text: Off Black `#111111`
- Background: Warm Cream `#faf9f6`
- Accent: Brand Orange `#ff5600`
- Border: Oat `#dedbd6`
- Muted: `#7b7b78`

### Prompt Template

> Create an OpenAva-style interface: warm cream background (`#faf9f6`), off-black text (`#111111`), oat borders (`#dedbd6`), sharp 4px buttons, Saans headings with negative tracking, and Brand Orange (`#ff5600`) only for key AI or brand emphasis. Prefer bordered surfaces over shadows.
