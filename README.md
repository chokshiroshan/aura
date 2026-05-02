# Aura

Your AI companion. Always on your screen.

Aura is a persistent AI companion for macOS that sees your screen, hears your voice, understands your intent, acts on your behalf, remembers who you are, and nudges you when it has something useful.

Not a chat window. Not a terminal. A companion that participates in your work.

## What It Does

- **Talks** — Click the orb, ask anything. Natural voice conversation too.
- **Sees** — Live screen streaming (1fps) to the vision model. Always knows what you're looking at.
- **Acts** — Runs commands, edits files, uses the browser via Codex's agent loop.
- **Remembers** — Persists memory across sessions via Codex.
- **Nudges** — Proactively offers help with visual suggestions when something useful is detected.

## Architecture

```
Aura App (.app bundle)
├── Swift UI (companion orb, audio, screen capture)
│     ↕ JSON-RPC over WebSocket
└── Codex binary (bundled, open source — Apache 2.0)
      ↕ ChatGPT Backend API
      GPT-5 / gpt-realtime
      ↑ Included in your ChatGPT subscription — $0 per token
```

No API keys. No per-token charges. Sign in with ChatGPT.

## Current Status

**v0.1 — Core Loop (current)**

- ✅ Swift UI companion (floating glowing orb)
- ✅ CodexClient — JSON-RPC WebSocket client for Codex backend
- ✅ AuraCoordinator — launches Codex, manages threads/voice/actions
- ✅ Codex OAuth (ChatGPT subscription auth)
- ✅ Audio capture (24kHz PCM16) + playback
- ✅ Continuous screen streaming (1fps → Codex vision)
- ✅ Proactive nudge engine (proactivity dial: silent/light/active/partner)
- ✅ Approval UI for shell commands and file changes
- ✅ Settings (voice, proactivity, connection)
- ✅ Conversation bubble (click orb to talk)
- ✅ End-to-end text chat through Codex
- ✅ Voice conversation through Codex realtime

See [PRODUCT_SPEC.md](PRODUCT_SPEC.md) for the full vision and [BUILD_PLAN.md](BUILD_PLAN.md) for the technical plan.

## Requirements

- macOS 14+ (Sonoma)
- Xcode Command Line Tools
- Rust toolchain (for Codex binary)
- ChatGPT subscription (Plus, Pro, or Team)

## Build

```bash
# Clone Codex into the project
git clone https://github.com/openai/codex.git codex-core
cd codex-core/codex-rs
cargo build --release -p codex-app-server

cd swift-ui
./build.sh     # Build .app
./build.sh dmg # Build .app + DMG
```

## File Structure

```
swift-ui/Sources/Aura/
├── AuraApp.swift              # App entry, menu bar, status item
├── AuraCoordinator.swift      # Central brain — wires everything together
├── Audio/
│   ├── AudioCapture.swift     # Mic capture (CoreAudio, 24kHz PCM16)
│   └── AudioPlayer.swift      # Plays Codex audio responses
├── Auth/
│   ├── ChatGPTAuth.swift      # OAuth PKCE flow
│   ├── KeychainStore.swift    # Secure token storage
│   └── OAuthCallbackServer.swift
├── Backend/
│   ├── CodexClient.swift      # JSON-RPC WebSocket to Codex
│   ├── OrbBackend.swift       # Backend protocol
│   ├── ChatGPTBackend.swift   # Direct ChatGPT (fallback)
│   └── OpenClawBackend.swift  # OpenClaw integration
├── Context/
│   └── ScreenContextExtractor.swift
├── Nudge/
│   └── NudgeEngine.swift      # Proactive scanning + nudge system
├── Screen/
│   └── ScreenStreamer.swift   # Continuous 1fps screen capture
├── Settings/
│   └── SettingsView.swift     # Proactivity, voice, connection settings
├── UI/
│   ├── Companion/OrbCompanionView.swift  # Glowing orb with state animations
│   ├── Conversation/
│   │   ├── ConversationBubble.swift      # Chat bubble UI
│   │   └── ApprovalCard.swift            # Command/file approval UI
│   ├── Floating/CompanionWindow.swift    # Floating panel management
│   ├── Nudge/NudgeChip.swift             # Proactive nudge indicator
│   └── Setup/SetupView.swift             # First-launch setup
├── Models/AppState.swift
├── Permissions/PermissionsManager.swift
└── Realtime/RealtimeClient.swift         # Direct WebSocket (fallback)
```

## License

- `swift-ui/`: MIT
- `codex-core/`: Apache 2.0 (© OpenAI)
