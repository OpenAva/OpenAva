---
name: map-visualization
description: Transform location and route data into clear map-ready markdown blocks for a map-capable message renderer.
metadata:
  display_name: Map Visualization
  emoji: 🗺️
---

# Map Visualization

Use this skill when the user asks to:

- Show locations on a map with markers.
- Visualize a route or path between points.
- Outline an area or boundary on a map.
- Combine markers, routes, and regions in one map.
- Turn structured location data into a rendered map block.

This skill outputs map markdown for the **in-app message renderer** (the chat message list UI) using fenced code blocks:

````markdown
```map
{ ...json... }
```
````

## Core Rules

- Always output valid JSON inside ` ```map ` blocks.
- Keep numeric fields as numbers, not strings.
- Use `lat` and `lon` for every coordinate.
- Keep each map focused on one spatial question.
- If data is incomplete or ambiguous, state assumptions briefly before the map.

## Runtime Target

- Target renderer: any chat/message renderer that supports ` ```map ` fenced blocks.
- Expected format: fenced code block with language tag `map` and a JSON object.
- If unsure, still output the exact ` ```map + JSON ` structure.

## Supported Fields

- `title`
- `height`
- `center`
- `span`
- `markers`
- `polylines`
- `polygons`

## JSON Schema

```json
{
  "title": "SF Delivery Route",
  "height": 260,
  "center": { "lat": 37.7749, "lon": -122.4194 },
  "span": 0.05,
  "markers": [
    {
      "lat": 37.7749,
      "lon": -122.4194,
      "title": "Warehouse",
      "tint": "blue"
    },
    {
      "lat": 37.7849,
      "lon": -122.4094,
      "title": "Dropoff",
      "tint": "#FF5A36"
    }
  ],
  "polylines": [
    {
      "coordinates": [
        { "lat": 37.7749, "lon": -122.4194 },
        { "lat": 37.7798, "lon": -122.4140 },
        { "lat": 37.7849, "lon": -122.4094 }
      ],
      "color": "blue"
    }
  ],
  "polygons": [
    {
      "coordinates": [
        { "lat": 37.7700, "lon": -122.4300 },
        { "lat": 37.7800, "lon": -122.4300 },
        { "lat": 37.7800, "lon": -122.4100 },
        { "lat": 37.7700, "lon": -122.4100 }
      ],
      "fillColor": "#22AA66",
      "strokeColor": "green"
    }
  ]
}
```

## Field Reference

### `title`

- Optional string shown above the map card.

### `height`

- Optional number.
- Runtime default: `240`.
- Runtime clamp: `160...360`.

### `center`

```json
{ "lat": 37.7749, "lon": -122.4194 }
```

- Optional object.
- If present, both `lat` and `lon` must be valid coordinates.
- If `center` is omitted, the renderer tries to fit the visible region to all valid coordinates in markers, polylines, and polygons.

### `span`

- Optional number controlling zoom/region size.
- Runtime default: `0.05`.
- Runtime clamp: `0.001...120`.

### `markers`

```json
[
  {
    "lat": 37.7749,
    "lon": -122.4194,
    "title": "Warehouse",
    "tint": "blue"
  }
]
```

- Optional array.
- Each marker supports:
  - `lat`
  - `lon`
  - `title?`
  - `tint?`

### `polylines`

```json
[
  {
    "coordinates": [
      { "lat": 37.7749, "lon": -122.4194 },
      { "lat": 37.7849, "lon": -122.4094 }
    ],
    "color": "blue"
  }
]
```

- Optional array.
- Each polyline supports:
  - `coordinates`
  - `color?`
- A polyline renders only if it has at least 2 valid coordinates.

### `polygons`

```json
[
  {
    "coordinates": [
      { "lat": 37.7700, "lon": -122.4300 },
      { "lat": 37.7800, "lon": -122.4300 },
      { "lat": 37.7800, "lon": -122.4100 }
    ],
    "fillColor": "#22AA66",
    "strokeColor": "green"
  }
]
```

- Optional array.
- Each polygon supports:
  - `coordinates`
  - `fillColor?`
  - `strokeColor?`
- A polygon renders only if it has at least 3 valid coordinates.

## Coordinate Rules

- Latitude must be between `-90` and `90`.
- Longitude must be between `-180` and `180`.
- Invalid coordinates are ignored by the renderer.

## Validity Rules

A map block is valid if it contains at least one of the following:

- A valid `center`
- At least one valid marker
- At least one polyline with 2 or more valid coordinates
- At least one polygon with 3 or more valid coordinates

If none of these conditions are met, the map should not be emitted.

## Color Rules

Color fields support:

- Named colors such as `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `gray`, `black`, `white`
- Hex colors such as `#FF5A36`
- 8-digit hex colors are also accepted by the runtime

## Element Selection Guide

- Use `markers` for named places or stops.
- Use `polylines` for routes, tracks, or ordered movement.
- Use `polygons` for zones, service areas, or boundaries.
- Use `center` + `span` when you want explicit framing.
- Omit `center` when you want the renderer to auto-fit the visible region.

## Workflow

1. Identify the spatial question: places, route, or area.
2. Normalize all coordinates into `lat` and `lon`.
3. Pick the minimum set of elements needed: markers, polylines, polygons.
4. Add `center` and `span` only when explicit framing helps.
5. Generate one ` ```map ` block per map.
6. Optionally add a short insight after the map.

## Quality Bar

- Do not fabricate coordinates.
- Do not output malformed JSON.
- Keep titles short and specific.
- Do not use strings for numeric coordinates.
- Ensure every polyline has at least 2 valid points.
- Ensure every polygon has at least 3 valid points.
- Keep each map focused and readable.
