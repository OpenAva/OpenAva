# OpenAva

> A native app for running personal AI agent teams on Apple devices.

OpenAva is a native Apple-platform app for running personal AI agents with real device context, persistent workspaces, and everyday automation. Its most distinctive idea is **agent teams**: instead of depending on a single general-purpose assistant, you can organize multiple personal agents into a durable working unit that collaborates around your tasks, context, and tools.

---

## Overview

OpenAva brings an agentic chat experience to iPhone and Mac with support for:

- personal agents with their own workspace and settings
- agent teams as a first-class way to coordinate delegated or collaborative workflows
- persistent chat sessions and conversation history
- durable memory and searchable past conversations
- skills, shortcuts, and scheduled automations
- device-aware actions such as files, notifications, media, contacts, calendar, and more
- configurable LLM providers and model endpoints
- local or remote gateway connectivity

The goal is simple: make AI agents feel like part of your personal computing environment, not detached web demos — and make multi-agent collaboration practical for everyday use.

## Agent Teams

OpenAva’s key differentiation is that teams are not treated as a temporary prompt trick. They are a core product surface.

With agent teams, OpenAva lets you:

- group multiple agents around one working context instead of forcing one agent to do everything
- keep specialized roles inside a persistent team structure
- use collaboration and delegation as part of normal day-to-day workflows
- manage a team as an ongoing asset, not a one-off experiment inside a single conversation

This makes OpenAva especially useful for users who want a more durable setup: for example, one agent can focus on planning, another on execution, another on review, while still operating inside the same personal environment.

## Highlights

| Area | What it enables |
|---|---|
| **Personal agents** | Create and switch between agents with distinct identity, workspace, and runtime context |
| **Agent teams** | Treat multi-agent collaboration as a first-class product concept, with persistent teams for coordinated work |
| **Chat and sessions** | Keep ongoing conversations, return to earlier sessions, and continue work over time |
| **Memory and history** | Let agents retain important long-term context while still being able to look back at past conversations |
| **Skills and automation** | Turn reusable workflows into skills, invoke them from chat or system integrations, and schedule recurring tasks |
| **Device integration** | Use your device as an execution surface for actions involving media, files, reminders, notifications, contacts, and other personal context |
| **Model flexibility** | Bring your own model providers and manage multiple model configurations inside the app |
| **Remote control** | Access and steer an active agent workflow from another device when needed |
| **Visibility** | Inspect runtime usage and manage agent behavior from the app’s settings surfaces |
| **Localization** | Available in English and Simplified Chinese |

## Memory

OpenAva keeps memory intentionally simple at the product level:

- agents can retain useful long-term context
- past conversations remain available for lookup when historical details matter
- ongoing sessions can preserve continuity across longer tasks

The goal is not to remember everything, but to help the agent keep what is worth carrying forward.

## Platform Notes

- OpenAva targets **iOS** and **macOS via Mac Catalyst**.
- Some device-integrated capabilities may vary by platform because Apple exposes different system APIs on iPhone/iPad and Mac.

## Requirements

- **iOS 18.0+** / **macOS 15.0+** (Mac Catalyst)
- **Xcode 16+**
- Access to a compatible OpenClaw gateway node
- At least one configured LLM endpoint

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/OpenAva/OpenAva.git
   cd OpenAva
   ```

2. Open `OpenAva.xcodeproj` in Xcode.

3. Let Swift Package Manager resolve dependencies.

4. Select the **OpenAva** scheme and build for a supported simulator or device.

5. Launch the app and configure your model provider in **Settings → LLM**.

6. Make sure the app can reach your gateway environment, then create your first agent and start chatting.

## Build from Command Line

```bash
xcodebuild -project OpenAva.xcodeproj -scheme OpenAva build
```
