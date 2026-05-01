# ✨ Aura

**Your AI companion. Always on your screen.**

Aura is a persistent AI companion for macOS that sees your screen, hears your voice, understands your intent, acts on your behalf, remembers who you are, and nudges you when it has something useful.

Not a chat window. Not a terminal. A companion that participates in your work.

## What Aura Does

- **Dictates** — hold a hotkey, speak, text appears anywhere
- **Talks** — natural voice conversation, back and forth
- **Sees** — live screen streaming, always knows what you're looking at
- **Acts** — runs commands, edits files, browses the web
- **Remembers** — persists memory across sessions
- **Nudges** — proactively offers help with visual suggestions

## How It Works

```
Aura App (.app bundle)
├── Swift UI (companion, audio, screen capture)
│     ↕ JSON-RPC over WebSocket
└── Codex binary (bundled, open source — Apache 2.0)
      ↕ ChatGPT Backend API
      GPT-5 / gpt-realtime
      ↑ Included in your ChatGPT subscription — $0 per token
```

No API keys. No per-token charges. Sign in with ChatGPT.

## Status

**v0.1 — Scaffold** (current)

- [x] Swift UI companion (floating glowing orb)
- [x] CodexClient — JSON-RPC WebSocket client for Codex backend
- [x] AuraCoordinator — launches Codex, manages threads/voice/actions
- [x] Codex OAuth (ChatGPT subscription auth)
- [x] Audio capture (24kHz PCM16)
- [x] Screen context extractor
- [ ] Codex binary bundled in .app
- [ ] End-to-end text chat
- [ ] Voice conversation
- [ ] Live screen streaming

See [PRODUCT_SPEC.md](PRODUCT_SPEC.md) for the full vision and [BUILD_PLAN.md](BUILD_PLAN.md) for the technical plan.

## Building

### Prerequisites

- macOS 14+ (Sonoma)
- Xcode Command Line Tools
- Rust toolchain (for Codex binary)

### Build Codex (Rust backend)

```bash
# Clone Codex into the project
git clone https://github.com/openai/codex.git codex-core
cd codex-core/codex-rs
cargo build --release -p codex-app-server
```

### Build Aura (Swift UI)

```bash
cd swift-ui
./build.sh        # Build .app
./build.sh dmg    # Build .app + DMG
```

## License

- **swift-ui/**: MIT
- **codex-core/**: Apache 2.0 (© OpenAI)
