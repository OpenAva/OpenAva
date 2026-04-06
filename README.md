# OpenAva

> Your personal AI agent, always in your pocket.

Maximizing the unique strengths of mobile devices as a **personal digital organ** — always on, sensors everywhere, deeply integrated with daily life.

---

## Overview

OpenAva is a native iOS/macOS application that brings a full agent runtime to mobile. It connects to local or remote OpenClaw gateway nodes, registers 60+ device capabilities as AI-callable tools, and delivers a streaming chat interface for real-time agent interaction. Agents can read sensors, manage files, search the web, query calendars, and more — all from a single conversation.

## Features

| Category | Details |
|---|---|
| **Agent Runtime** | Full OpenClaw protocol support; multi-agent sessions; agent presets & onboarding wizard |
| **Device Tools** | Camera, Photos, Screen capture, Location, Contacts, Calendar, Reminders, Motion, Apple Watch |
| **Web & Search** | Web search with reranking, page fetch, free image search, YouTube transcript extraction |
| **Files & Memory** | Full filesystem access (`fs_*`); durable agent memory topics; transcript-backed historical recall |
| **Data** | Weather forecast (Open-Meteo); China A-share market data; device status & diagnostics |
| **Chat UI** | Streaming markdown rendering, tool-call display, multi-session management |
| **Speech** | Text-to-speech via ElevenLabs; system speech synthesizer fallback; on-device STT |
| **Connectivity** | Bonjour-based local gateway discovery; TLS-pinned remote relay |
| **Widgets** | Live Activities for Cron jobs and running Tasks |
| **Skills** | Per-agent skill toggles; customizable system prompt; `skill_load` for markdown playbooks |
| **LLM Config** | Add and manage multiple LLM provider endpoints (OpenAI, Claude, and compatible APIs) |
| **Localization** | English and Simplified Chinese |

## Tools

Tools are registered per-session and exposed to the LLM as callable functions. Categories and representative tools:

| Category | Tools |
|---|---|
| **Camera & Media** | `camera_snap`, `camera_clip`, `camera_list`, `photos_latest`, `screen_record`, `image_remove_background` |
| **Location & Motion** | `location_get`, `motion_activity`, `motion_pedometer`, `watch_status`, `watch_notify` |
| **Communication** | `contacts_search`, `contacts_add`, `notify_user`, `speech_transcribe` |
| **Scheduling** | `calendar_events`, `calendar_add`, `reminders_list`, `reminders_add`, `cron` |
| **Web & Search** | `web_search`, `web_fetch`, `image_search`, `youtube_transcript` |
| **Files** | `fs_read`, `fs_write`, `fs_delete`, `fs_list`, `fs_mkdir`, `fs_copy`, `fs_move` |
| **Memory** | `memory_recall`, `memory_upsert`, `memory_forget`, `memory_transcript_search` |
| **Data & Device** | `weather_get`, `a_share_market`, `device_status`, `device_info`, `skill_load` |

> Some tools (camera, location, calendar, etc.) are unavailable on macOS Catalyst due to platform restrictions.

## Architecture

```
OpenAva (iOS App)
├── OpenAva/                  Main application target (SwiftUI, iOS 18+)
│   ├── App/                AppDelegate, container, dependency injection
│   ├── Features/
│   │   ├── Agent/          Agent onboarding & local agent creation
│   │   ├── Chat/           Chat root view, session delegate, tool provider
│   │   └── Settings/       LLM, skill, and agent context settings
│   └── Runtime/
│       ├── Agent/          Prompt building, skill/template management
│       ├── LLM/            LLM client integration
│       ├── Session/        Node session lifecycle
│       └── Tools/          Device tool definitions & registry
│
├── OpenClawKit/            Reusable SDK (iOS 18 / macOS 15) — usable independently
│   ├── OpenClawProtocol    Wire protocol types & interfaces
│   └── OpenClawKit         Gateway, tools, audio, device integrations
│
├── ChatKit/                Chat rendering library (iOS 17+)
│   ├── ChatClient          Streaming message client
│   └── ChatUI              UIKit-based chat interface
│
└── ActivityWidget/         Live Activities extension
    ├── CronLiveActivity     Cron job progress display
    └── TaskLiveActivity     Agent task status display
```

## Requirements

- **iOS 18.0+** / **macOS 15.0+** (Mac Catalyst)
- **Xcode 16+** (Swift 6)
- An accessible OpenClaw gateway node (local via Bonjour or remote relay)

## Getting Started

1. Clone the repository:
   ```bash
   git clone <repo-url>
   cd OpenAva
   ```

2. Open `OpenAva.xcodeproj` in Xcode and let Swift Package Manager resolve dependencies automatically.

3. Select the **OpenAva** scheme, choose your target device or simulator, and build.

4. Open **Settings → LLM** to add an LLM provider endpoint (OpenAI-compatible API key and base URL required).

### Build from command line

```bash
xcodebuild \
  -project OpenAva.xcodeproj \
  -scheme OpenAva \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build
```
