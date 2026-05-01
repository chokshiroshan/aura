# 🛰️ Orb

**Your AI companion. Everywhere.**

Orb lives on your desktop, in the cloud, and on your phone. Same brain, same memory, every surface.

## First Launch

```
┌─────────────────────────────────┐
│         🛰️ Orb                  │
│   "Your AI companion, everywhere"│
│                                  │
│  ┌────────────────────────────┐  │
│  │ 🔗 Connect OpenClaw       │  │
│  │ Full: sync, memory, skills │  │
│  └────────────────────────────┘  │
│  ┌────────────────────────────┐  │
│  │ 💬 Use ChatGPT            │  │
│  │ Voice companion, free      │  │
│  └────────────────────────────┘  │
│                                  │
│       [ Get Started ]            │
└─────────────────────────────────┘
```

## Architecture

```
Orb Desktop App (SwiftUI, macOS 14+)
├── Glowing orb companion (floating, all spaces)
├── Backend abstraction (pick your brain)
│   ├── OpenClawBackend → your self-hosted agent
│   └── ChatGPTBackend → Codex OAuth, local only
├── Voice interaction (Realtime API or OpenClaw)
├── Screen context (screenshot → vision)
└── Shared memory (synced via OpenClaw or local)
```

## Two Paths

| | OpenClaw | ChatGPT |
|---|---|---|
| **Cost** | Free (your infra) | Free (your subscription) |
| **Setup** | Gateway URL + API key | OAuth login |
| **Memory** | Shared, synced, persistent | Local only |
| **Skills** | Full OpenClaw skill system | Voice Q&A only |
| **Multi-device** | Yes (cloud + desktop + mobile) | Desktop only |
| **Always-on** | Yes (cloud agent runs 24/7) | No |

## Build

```bash
git clone https://github.com/chokshiroshan/orb.git
cd orb
./build.sh
cp -r build/Orb.app /Applications/
```

Requires macOS 14+ (Sonoma) and Xcode Command Line Tools.

## The Vision

Orb is the consumer face of OpenClaw — one AI companion across all your devices:

- **☁️ Cloud Orb** — always on, heavy tasks, research (your VPS)
- **🖥️ Desktop Orb** — floating companion, screen context, app control (macOS)
- **📱 Mobile Orb** — push notifications, quick interactions (iOS/Android)

Same memory. Same personality. Different capabilities per device.

## License

MIT
