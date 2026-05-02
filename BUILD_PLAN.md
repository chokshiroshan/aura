# Aura Build Plan

_Last updated: 2026-05-02_

## Architecture

```
Aura App (.app bundle)
├── Swift UI (companion, audio I/O, screen capture, nudges)
│     ↕ JSON-RPC over WebSocket (ws://127.0.0.1:8080)
└── Codex binary (bundled, background process)
      ↕ ChatGPT Backend API
      GPT-5 / gpt-realtime
      ↑ Included in user's ChatGPT subscription — $0 per token
```

## Why Codex (Not Build From Scratch)

| What we need | Build it | Codex |
|---|---|---|
| Shell execution | Months | ✅ exec, command-exec crates |
| File read/write | Weeks | ✅ file-system, fs_api |
| Computer use | Months | ✅ core agent |
| Browser use | Months | ✅ MCP + connectors |
| Memory | Weeks | ✅ memories/read-write |
| Tool/skills framework | Months | ✅ core-skills, skills |
| MCP support | Weeks | ✅ codex-mcp |
| Sandbox/security | Months | ✅ linux-sandbox |
| Always-on voice | Weeks | ✅ realtime conversation |
| Agent reasoning loop | Months | ✅ core agent loop |
| OAuth auth | Days | ✅ login crate |

**Months of work saved.** Codex does the heavy lifting; Aura is the experience layer.

## Protocol: JSON-RPC over WebSocket

Codex app-server speaks JSON-RPC. Our `CodexClient` sends:

```json
{ "id": 1, "method": "initialize", "params": { "clientInfo": { "name": "Aura", "version": "0.1.0" } } }
```

Key methods:
- `initialize` — handshake
- `account/read` — check auth
- `account/login/start` — OAuth
- `thread/start` — create conversation thread
- `turn/start` — send message, get response (supports LocalImage for vision)
- `thread/realtime/start` — start voice session
- `thread/realtime/appendAudio` — send audio
- `thread/realtime/stop` — end voice session
- `__resolve__` — approve/deny tool requests

## Build Phases

### Phase 1: Core Loop ✅
- [x] CodexClient.swift (JSON-RPC WebSocket)
- [x] AuraCoordinator (Codex lifecycle, threads, events)
- [x] Floating orb companion (state-reactive animations)
- [x] Conversation bubble (click orb to talk)
- [x] Text chat through Codex
- [x] ChatGPT sign-in via Codex OAuth

### Phase 2: Voice ✅
- [x] AudioCapture (CoreAudio 24kHz PCM16)
- [x] AudioPlayer (PCM16 playback)
- [x] Voice session via Codex realtime
- [x] Orb state: listening (cyan) → speaking (green)

### Phase 3: Eyes ✅
- [x] ScreenStreamer (continuous 1fps capture)
- [x] Frames to Codex via LocalImage input
- [x] Screen context attached to text turns
- [x] Unlimited vision via free Codex tokens

### Phase 4: Agent ✅ (via Codex)
- [x] Approval card UI for shell commands
- [x] Approval card UI for file changes
- [x] Auto-approve or manual approve/deny
- [x] Codex handles: shell exec, file ops, sandboxing

### Phase 5: Brain ✅
- [x] NudgeEngine (proactive screen scanning)
- [x] Proactivity dial (silent/light/active/partner)
- [x] NudgeChip UI (floating indicator)
- [x] Memory via Codex (cross-session)

### Phase 6: Polish (Next — needs Mac)
- [ ] Build and test on macOS
- [ ] Fix compilation issues
- [ ] Test Codex binary launch + WebSocket
- [ ] Test OAuth flow end-to-end
- [ ] Test voice conversation
- [ ] Test screen streaming
- [ ] DMG installer
- [ ] Landing page

### Phase 7: Ship
- [ ] GitHub release
- [ ] HN / Reddit launch
- [ ] Standalone ChatFlow also available (separate project)
