# 🛰️ Orb

**Your AI companion. Everywhere.**

Built on [OpenAI Codex](https://github.com/openai/codex) (Apache 2.0).

## What Orb Is

Orb takes Codex — an open-source coding agent — and gives it a soul.

- **Floating companion** on your desktop (glowing orb, always there)
- **Voice-first** — talk to it naturally, it talks back
- **Full agent** — file access, shell commands, web search, code
- **Free** — uses your existing ChatGPT subscription (Plus/Pro)
- **OpenClaw compatible** — connect your OpenClaw instance for multi-device sync

## How It Works

```
Orb App (Swift UI)
    ↓ JSON-RPC
Codex App Server (bundled, open source)
    ↓ ChatGPT Backend API
GPT-4.5 / GPT-4o / gpt-realtime
    ↑ Included in your ChatGPT subscription
```

No API keys. No per-token charges. Just sign in with ChatGPT.

## Structure

```
orb/
├── codex-core/       → Forked OpenAI Codex (Apache 2.0)
│   └── codex-rs/     → Rust source (app-server, auth, voice, tools, memory)
│
└── swift-ui/         → Orb desktop companion (Swift/SwiftUI)
    ├── Sources/Orb/  → Floating orb, setup flow, settings
    └── build.sh      → Build .app bundle (includes codex binary)
```

## Setup Flow

```
First Launch:
1. "Sign in with ChatGPT" → official OAuth
2. Orb appears on your desktop
3. Talk to it. Done.

Optional:
4. "Connect OpenClaw" → multi-device sync, skills, always-on agent
```

## Building

```bash
# Build Codex (Rust)
cd orb/codex-core/codex-rs
cargo build --release -p codex-app-server

# Build Orb UI (Swift, requires macOS)
cd ../../swift-ui
./build.sh

# The .app bundles the codex binary inside
```

## Why Fork Codex?

- **Official OAuth** — no hacks, no reverse engineering
- **Free inference** — GPT-4.5, GPT-4o, voice via ChatGPT subscription
- **Battle-tested** — millions of Codex users, OpenAI maintains it
- **Apache 2.0** — full permission to fork, modify, distribute
- **Rich features** — memory, tools, skills, sandboxing, already built

We add: the companion UI, the always-on experience, the OpenClaw integration.

## License

- **codex-core/**: Apache 2.0 (© OpenAI)
- **swift-ui/**: MIT (© Roshan Choks)
