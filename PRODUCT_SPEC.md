# Aura Product Spec

_Version: 0.1 — 2026-05-01_

## What Aura Is

A persistent AI companion that lives on your Mac desktop. It sees your screen, hears your voice, understands your intent, acts on your behalf, remembers who you are, and nudges you when it has something useful.

Not a chat window. Not a terminal. Not a phone app. A companion that participates in your work.

## The Technical Breakthrough

1. **Unlimited Realtime API via Codex OAuth** — Codex's OAuth gives access to ChatGPT backend. 15M tokens, resets instantly. GPT-realtime for voice, GPT-5 for reasoning. Cost: $0/user.

2. **Codex open-source agent backend** (Apache 2.0) — Shell exec, file ops, browser use, computer use, MCP, memory, sandboxing. 98 Rust crates maintained by OpenAI.

3. **macOS native companion UI** — NSPanel floating on top of everything. Full-screen compatible, multi-space. Screen capture, text detection, text injection.

4. **Live screen streaming** — Because tokens are unlimited, we can push frames to the vision model continuously (1-2 fps). Nobody else can afford this. Aura watches your screen in near real-time.

## Interaction Model

### Entry Points
- Click Aura → opens conversation
- Hold hotkey → dictation mode (speak → text at cursor)
- Tap hotkey → quick voice command
- Aura nudge → proactive suggestion (glow arrow + chip)
- Right-click text → utility menu (rewrite / shorten / translate)

### Exit Points
- Voice (Aura speaks through speakers)
- Text injection (typed at cursor)
- Action result (brief status from orb)
- Visual nudge (glow + chip near cursor)
- Silence (nothing)

### Proactivity Dial
- Silent — only responds when asked
- Light — only for errors and obvious improvements
- Active — offers help when it thinks it can be useful
- Partner — actively suggests, reminds, and assists

## Capabilities

1. **Dictation** — ChatFlow behavior. Hold hotkey, speak, release, text appears anywhere.
2. **Voice conversation** — Natural back-and-forth. Ask questions, brainstorm, explain.
3. **Screen awareness** — Live screen streaming to vision model. Aura always knows what you see.
4. **Text utilities** — Rewrite, summarize, expand, translate, fix tone, shorten.
5. **Workspace agent** — Read files, edit files, run terminal commands, search code, debug.
6. **Browser / computer use** — Open pages, click, fill, navigate, fetch info from sites.
7. **Persistent memory** — Remember names, projects, habits, preferences, active tasks.

## Architecture

```
Aura App (.app bundle)
├── Swift UI (companion, audio, screen capture, text injection)
│     ↕ JSON-RPC over WebSocket (localhost)
└── Codex binary (bundled, background process)
      ↕ ChatGPT Backend API
      GPT-5 / gpt-realtime (free via subscription)
```

## Version Roadmap

**v0.1 — Core Loop (Week 1)**
- Codex binary bundled and launching
- Floating companion on screen (orb)
- ChatGPT sign-in (Codex OAuth)
- Text chat through Codex
- Companion state animations

**v0.2 — Voice (Week 2)**
- Voice conversation via Realtime API
- Push-to-talk hotkey
- Aura speaks back (audio output)
- Server-side VAD
- Dictation mode

**v0.3 — Eyes (Week 3)**
- Live screen capture streaming to Realtime API (1-2 fps)
- Active app detection
- Screen-aware responses

**v0.4 — Hands (Week 4)**
- Shell command execution (Codex)
- File read/write
- Apply patches
- Agent loop fully working

**v0.5 — Brain (Week 5)**
- Persistent memory (Codex MemoryTool / SQLite)
- Cross-session recall
- Proactive visual nudges (glow arrows, suggestion chips)
- Proactivity dial

**v0.6 — Polish (Week 6)**
- Browser use
- Text utilities
- Setup/onboarding flow
- Settings UI
- Hotkey customization

**v0.7 — Personality (Week 7)**
- Cat mascot with expressions (Lottie)
- Voice selection
- Custom instructions
- Personality tuning

**v0.8 — Platform (Week 8)**
- OpenClaw integration (multi-device sync)
- Plugin system
- MCP connectors

**v0.9 — Beta (Week 9)**
- Bug fixes, performance
- DMG installer
- Landing page

**v1.0 — Launch (Week 10)**
- GitHub release
- HN / Reddit launch
- Standalone ChatFlow also available
- Public beta

## Competitive Landscape

- ChatGPT: web app, no screen awareness, no actions, $20/mo
- Copilot: editor only, no voice, no screen, $10/mo
- Wispr Flow: voice dictation only, $30/mo
- Clicky: early stage, VC subsidized, TBD pricing
- Aura: desktop companion, live screen, voice, actions, memory, proactive — free with ChatGPT sub, $0/user cost to us

## Why This Wins

Every competitor pays $0.05-0.06/min per user for inference. We pay $0. Every user brings their own ChatGPT subscription. We can scale to millions with zero marginal cost.

And because tokens are unlimited, we can do what nobody else can: stream the screen live to the vision model. That single capability — continuous visual awareness — makes Aura feel fundamentally different from every other AI tool.
