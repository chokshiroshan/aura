# Orb Build Plan

_Last updated: 2026-05-01_

## Architecture

```
Orb App (.app bundle)
├── Swift UI (companion, audio I/O, setup flow)
│     ↕ JSON-RPC over WebSocket (ws://127.0.0.1:8080)
└── Codex binary (bundled, launched as background process)
      ↕ ChatGPT Backend API
      GPT-5 / GPT-4o / gpt-realtime
      ↑ Included in user's ChatGPT subscription — $0 per token
```

## Why Fork Codex (Not ChatFlow)

| What we need | ChatFlow | Codex |
|---|---|---|
| Shell execution | Build from scratch | ✅ exec, command-exec crates |
| File read/write | Build from scratch | ✅ file-system, fs_api |
| Computer use | Build from scratch | ✅ core agent |
| Browser use | Build from scratch | ✅ MCP + connectors |
| Memory | Build SQLite | ✅ memories/read-write |
| Tool/skills framework | Build from scratch | ✅ core-skills, skills |
| MCP support | Build from scratch | ✅ codex-mcp |
| Sandbox/security | Build from scratch | ✅ linux-sandbox |
| Always-on voice | ❌ push-to-talk only | ✅ realtime conversation |
| Multi-step agent reasoning | Build from scratch | ✅ core agent loop |
| OAuth auth | ✅ Already has | ✅ Same (login crate) |

**Months of work saved.** Codex does the heavy lifting; Orb is the experience layer.

## Protocol: JSON-RPC over WebSocket

Codex app-server speaks JSON-RPC. Our Swift `CodexClient` sends:

```json
{ "id": 1, "method": "initialize", "params": { "clientInfo": { "name": "Orb", "version": "0.1.0" } } }
```

Key methods:
- `initialize` — handshake
- `account/read` — check auth
- `account/login/start` — OAuth
- `thread/start` — create conversation
- `turn/start` — send message, get response
- `thread/realtime/start` — start voice session
- `thread/realtime/appendAudio` — send audio
- `thread/realtime/stop` — end voice session
- `fs/readFile`, `fs/writeFile` — file ops
- `command/exec` — run shell commands
- `mcpServer/tool/call` — MCP tools
- `memory/reset`, `thread/read` — memory

## Files Written

```
orb/
├── codex-core/           → Codex source (Apache 2.0)
│   └── codex-rs/         → 98 Rust crates
│
├── swift-ui/             → Orb desktop companion (MIT)
│   ├── Sources/Orb/
│   │   ├── OrbApp.swift              → App entry, launches Codex + companion
│   │   ├── OrbCoordinator.swift      → Central state, glues everything together
│   │   ├── Backend/
│   │   │   ├── CodexClient.swift     → JSON-RPC WebSocket client ← NEW
│   │   │   ├── OrbBackend.swift      → Protocol definition
│   │   │   ├── ChatGPTAuth.swift     → OAuth (fallback, Codex handles this)
│   │   │   └── OpenClawBackend.swift → OpenClaw integration
│   │   ├── UI/
│   │   │   ├── Floating/CompanionWindow.swift  → Floating NSPanel
│   │   │   ├── Companion/OrbCompanionView.swift → Glowing orb view
│   │   │   └── Setup/SetupView.swift            → Setup flow
│   │   ├── Audio/AudioCapture.swift   → Mic capture
│   │   ├── Realtime/RealtimeClient.swift → Direct WS (fallback)
│   │   ├── Context/ScreenContextExtractor.swift → Screenshots
│   │   └── Permissions/PermissionsManager.swift → macOS perms
│   └── build.sh         → Build .app (bundles Codex binary)
│
├── BUILD_PLAN.md        → This file
└── README.md            → Project overview
```

## Build Phases

### Phase 1: MVP — Text + Voice Companion (This Week)
- [x] Codex source cloned
- [x] CodexClient.swift written (JSON-RPC over WebSocket)
- [x] OrbCoordinator rewritten to use Codex backend
- [x] OrbApp.swift updated (launches Codex binary + connects)
- [ ] Codex binary compiles on Linux → cross-compile for macOS arm64
- [ ] Test JSON-RPC connection end-to-end
- [ ] Bundled binary in .app
- [ ] Text chat through Codex (turn/start → turn/started → turn/completed)
- [ ] Voice through Codex (thread/realtime/start → appendAudio → stop)
- [ ] Orb animations react to state

### Phase 2: Agent Capabilities (Week 2)
- [ ] Shell commands (command/exec)
- [ ] File operations (fs/readFile, fs/writeFile)
- [ ] Screen context piped through vision
- [ ] Memory persistence
- [ ] MCP tools

### Phase 3: Personality & Polish (Week 3)
- [ ] Cat mascot (Lottie animation)
- [ ] Hatch process (unique companion per user)
- [ ] Voice selection
- [ ] Custom instructions
- [ ] OpenClaw integration (multi-device)

### Phase 4: Ship (Week 4)
- [ ] DMG installer
- [ ] Landing page
- [ ] GitHub release
- [ ] HN / Reddit launch
