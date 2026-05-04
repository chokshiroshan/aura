# Aura Build Plan

_Last updated: 2026-05-04_

## Architecture

```
Aura App (.app bundle)
├── Swift UI Layer
│   ├── Pet Companion (spritesheet renderer)
│   ├── Jarvis Overlay (dynamic UI — menus, highlights, cards, forms)
│   ├── Conversation Bubble (text/voice chat)
│   ├── Audio I/O (mic capture, speaker playback)
│   └── Screen Capture (1fps → Codex vision)
│     ↕ JSON-RPC over WebSocket (ws://127.0.0.1:8080)
└── Codex binary (bundled, background process)
      ↕ ChatGPT Backend API
      GPT-5 / gpt-realtime (free via subscription)
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
- [x] CodexClient.swift (JSON-RPC WebSocket, ~620 LOC)
- [x] AuraCoordinator (Codex lifecycle, threads, events, ~600 LOC)
- [x] Floating orb companion (state-reactive animations)
- [x] Conversation bubble (click orb to talk)
- [x] Text chat through Codex
- [x] ChatGPT sign-in via Codex OAuth
- [x] Codex binary launch from app bundle
- [x] RealtimeClient.swift (direct WebSocket fallback, ~400 LOC)
- [x] ChatGPTAuth.swift (PKCE OAuth, ~355 LOC)
- [x] SetupView (onboarding/permissions flow)

### Phase 2: Voice ✅
- [x] AudioCapture (CoreAudio IOProc, 24kHz PCM16, ~280 LOC)
- [x] AudioPlayer (PCM16 playback queue, ~84 LOC)
- [x] Voice session via Codex realtime (start/append/stop)
- [x] Orb state: listening (cyan) → speaking (green)
- [x] Voice toggle in conversation bubble (mic button)
- [x] Realtime transcript streaming (partial + final)
- [x] Audio playback via speaker

### Phase 3: Eyes ✅
- [x] ScreenStreamer (continuous 1fps capture, ~244 LOC)
- [x] Multi-display support (composite all displays)
- [x] Frames to Codex via LocalImage input
- [x] Screen context attached to text turns (configurable)
- [x] Screen recording permission check + prompt
- [x] Realtime screen snapshots during voice sessions
- [x] Unlimited vision via free Codex tokens
- [x] ScreenContextExtractor (GPT-4o-mini vision, ~260 LOC)

### Phase 4: Agent 🟡 (Partial)
- [x] Codex handles: shell exec, file ops, sandboxing (via Codex binary)
- [x] ApprovalCard.swift UI component exists
- [ ] **Approval auto-approves everything** — no real approve/deny flow yet (TODO in code)
- [ ] ApprovalCard NOT wired into ConversationBubble
- [ ] Shell command approval UI not shown to user
- [ ] File change approval UI not shown to user

### Phase 5: Brain 🟡 (Partial)
- [x] NudgeEngine (timer-based scanning via Codex, ~188 LOC)
- [x] Proactivity dial (silent/light/active/partner) in settings
- [x] NudgeChip UI (floating indicator)
- [ ] NudgeEngine scanning depends on Codex connection — untested
- [ ] Memory via Codex — `getMemories()` returns empty array (stub)
- [ ] Cross-session recall not implemented
- [ ] Nudge scan responses untested (needs Mac)

### Phase 6: Jarvis Layer 🔄 (NEW)
The dynamic UI system — Aura doesn't just reply with text, it renders interactive UI on screen.

#### 6a: UI Action Protocol
- [ ] Define `UIAction` enum — structured responses from Codex
- [ ] Extend `TurnEvent` to parse UI actions from agent messages
- [ ] Intercept structured JSON in agent responses (markers like `[UI:...]` or dedicated tool output)

Supported UI action types:
```swift
enum UIAction {
    case options(title: String, choices: [Choice])    // Picked choice → sent back to Codex
    case highlight(rect: CGRect, label: String?)       // Red ring on screen at coordinates
    case form(title: String, fields: [FormField])      // Input fields overlay
    case statusCard(title: String, items: [StatusItem]) // Mini dashboard
    case approval(title: String, detail: String, actions: [String])
    case pointAt(rect: CGRect)                         // Pet moves + points at screen region
    case confirm(message: String)                      // Yes/No overlay
}
```

#### 6b: Overlay Renderer
- [ ] `OverlayWindow` — full-screen transparent NSPanel, `ignoresMouseEvents = false` when action is active
- [ ] `OverlayRenderer` — draws highlights, circles, arrows using CAShapeLayer
- [ ] `OptionsMenuView` — floating card with clickable options (generated on-the-fly)
- [ ] `FormOverlayView` — input fields rendered over the relevant screen area
- [ ] `StatusCardView` — mini dashboard (test results, file changes, task progress)
- [ ] `ConfirmView` — yes/no with voice support ("say yes to confirm")

#### 6c: Voice-Driven Menus
- [ ] When options are presented in voice mode, Aura reads them aloud
- [ ] User says "the first one" or "option two" → selection sent back to Codex
- [ ] Works without looking at the screen — pure voice interaction
- [ ] Timeout after 10s → auto-dismiss or repeat options

#### 6d: Context-Aware Positioning
- [ ] UI elements appear near the relevant screen content
- [ ] If Aura highlights a UI element, the options menu appears next to it
- [ ] If Aura points at something, pet moves to the nearest screen edge
- [ ] Smart clamping to keep overlays on-screen

#### 6e: Screen Pointing (Pet + Overlay Combo)
- [ ] Pet repositions near target area
- [ ] Overlay draws highlight ring/arrow at coordinates
- [ ] Optional: dim rest of screen to focus attention
- [ ] Auto-dismiss after interaction or timeout

### Phase 7: Pet System 🔄 (NEW)
Codex-style pixel pet companion adapted for Aura's emotional states.

#### 7a: Pet Renderer
- [ ] `PetSpriteView` — renders spritesheet animation in a floating NSPanel
- [ ] Supports WebP/PNG atlas format (compatible with Codex hatch-pet output)
- [ ] Configurable frame rate (8-12fps for idle, 16fps for active states)
- [ ] Smooth transitions between animation states (crossfade or cut)
- [ ] Pet panel is separate from orb panel — can be moved independently

#### 7b: Aura Pet Atlas Spec
12 animation rows × 8 frames per row (12×8 atlas).
Each frame: 192×208px. Total atlas: 1536×2496px.

```
Row  0: idle          — Breathing, blinking, subtle sway
Row  1: listening     — Ears up, alert, leaning forward
Row  2: thinking      — Paw on chin, eyes looking up
Row  3: speaking      — Mouth moving, animated gestures
Row  4: happy         — Big smile, bouncing, sparkles
Row  5: confused      — Head tilt, question eyes
Row  6: sad           — Droopy ears, looking down
Row  7: sleeping      — Curled up, Zzz
Row  8: waving        — Waving paw
Row  9: excited       — Stars in eyes, rapid bounce
Row 10: working       — Focused, tiny typing motion
Row 11: error         — Flat, glitchy, dizzy
```

Directional overlays (separate small sprites):
```
point-up-left, point-up-right, point-left, point-right (4 poses)
```

#### 7c: State → Animation Mapping
```swift
enum AuraState {
    case idle       → row 0 (idle)
    case listening  → row 1 (listening)
    case processing → row 2 (thinking)
    case speaking   → row 3 (speaking)
    case sleeping   → row 7 (sleeping)
}
// Bonus states triggered by context:
// happy/excited after successful actions
// confused when unsure
// error on failures
// working during long tool executions
```

#### 7d: Hatch Pipeline
Adapt Codex's `hatch-pet` skill for Aura's extended spec.
- [ ] Fork the hatch-pet skill with Aura's 12-row spec
- [ ] Default pet: "Pixel" the cat (included in app bundle)
- [ ] Generate custom pets from description or reference image
- [ ] Pet packs: download/load additional pet atlases
- [ ] Pet selector UI in settings

#### 7e: Pet Behavior
- [ ] Pet wanders on screen edge when idle (slow drift)
- [ ] Pet moves to active monitor when user switches spaces
- [ ] Pet reacts to notifications (bounces on nudge)
- [ ] Pet hides behind windows when "sleeping"
- [ ] Pet appears on screen near pointer when summoned

### Phase 8: Polish (Needs Mac)
- [ ] Build and test on macOS
- [ ] Fix compilation issues
- [ ] Test Codex binary launch + WebSocket
- [ ] Test OAuth flow end-to-end
- [ ] Test voice conversation
- [ ] Test screen streaming
- [ ] **Wire real approval flow** — replace auto-approve with ApprovalCard UI
- [ ] Test Jarvis overlay interactions
- [ ] Test pet animations + state transitions
- [ ] DMG installer
- [ ] Landing page
- [ ] Build and test on macOS
- [ ] Fix compilation issues
- [ ] Test Codex binary launch + WebSocket
- [ ] Test OAuth flow end-to-end
- [ ] Test voice conversation
- [ ] Test screen streaming
- [ ] Test Jarvis overlay interactions
- [ ] Test pet animations + state transitions
- [ ] DMG installer
- [ ] Landing page

### Phase 9: Ship
- [ ] GitHub release
- [ ] HN / Reddit launch
- [ ] Standalone ChatFlow also available (separate project)

## File Structure (Current + Planned)

```
swift-ui/Sources/Aura/
├── AuraApp.swift                    ✅ App entry + menu bar
├── AuraCoordinator.swift            ✅ Central brain
├── Backend/
│   ├── CodexClient.swift            ✅ JSON-RPC client
│   ├── ChatGPTBackend.swift         ✅ Direct Realtime fallback
│   ├── OpenClawBackend.swift        ✅ OpenClaw integration
│   └── OrbBackend.swift             ✅ Protocol definition
├── Auth/
│   ├── ChatGPTAuth.swift            ✅ OAuth flow
│   ├── KeychainStore.swift          ✅ Token storage
│   └── OAuthCallbackServer.swift    ✅ localhost callback
├── Audio/
│   ├── AudioCapture.swift           ✅ Mic → PCM16
│   └── AudioPlayer.swift            ✅ PCM16 → Speaker
├── Screen/
│   └── ScreenStreamer.swift         ✅ 1fps screen → PNG
├── Context/
│   └── ContextManager.swift         ✅ Prompt context builder
├── Nudge/
│   └── NudgeEngine.swift            ✅ Proactive scanning
├── Permissions/
│   └── PermissionsManager.swift     ✅ Mic, accessibility, screen
├── Settings/
│   └── SettingsView.swift           ✅ Settings window
├── Models/
│   └── AppState.swift               ✅ Config, state types
│
├── UI/
│   ├── Companion/
│   │   └── OrbCompanionView.swift   ✅ Glowing orb
│   ├── Floating/
│   │   └── CompanionWindow.swift    ✅ Orb + bubble panels
│   ├── Conversation/
│   │   ├── ConversationBubble.swift ✅ Chat interface
│   │   └── ApprovalCard.swift       ✅ Approve/deny actions
│   ├── Nudge/
│   │   └── NudgeChip.swift          ✅ Nudge indicator
│   │
│   ├── Pet/                          🔄 NEW
│   │   ├── PetSpriteView.swift       — Spritesheet renderer
│   │   ├── PetAtlas.swift            — Atlas parser (WebP/PNG)
│   │   └── PetBehavior.swift         — Wander, react, reposition
│   │
│   └── Overlay/                       🔄 NEW
│       ├── OverlayWindow.swift        — Full-screen transparent panel
│       ├── OverlayRenderer.swift      — CAShapeLayer drawing
│       ├── OptionsMenuView.swift      — Dynamic option cards
│       ├── HighlightView.swift        — Screen highlight ring
│       ├── FormOverlayView.swift      — Dynamic input forms
│       ├── StatusCardView.swift       — Mini dashboards
│       └── ConfirmView.swift          — Yes/No voice dialog
│
└── Resources/
    └── Pets/
        └── pixel/                     🔄 Default pet
            ├── pet.json               — Atlas metadata
            └── spritesheet.webp       — 12×8 animation atlas
```

## Jarvis Interaction Examples

**Scenario 1: Code Review**
```
User: "What do you think of this code?" (voice)
Aura: [looks at screen] → "I see 3 issues in your auth module."
      [overlay highlights each issue on screen]
      [options menu appears]:
        ┌──────────────────────────┐
        │ 3 issues found           │
        │                          │
        │ 1. SQL injection L42     │
        │ 2. Missing error handling │
        │ 3. Hardcoded secret L89  │
        │                          │
        │ ▸ Fix all three          │
        │ ▸ Fix #1 only            │
        │ ▸ Show me more details   │
        └──────────────────────────┘
User: "Fix all three" (voice or click)
Aura: [Codex applies fixes] → "Done. 3 files changed."
      [pet does happy animation]
```

**Scenario 2: Research**
```
User: "Compare React vs Vue for our project" (text)
Aura: "Based on your TypeScript codebase, here's my take:"
      [status card appears]:
        ┌──────────────────────────┐
        │ React vs Vue             │
        │                          │
        │ Your codebase: TS + Vite │
        │ Team size: 3             │
        │                          │
        │ React ████████░░ 78% fit │
        │ Vue   ██████░░░░ 62% fit │
        │                          │
        │ Recommendation: React    │
        │ Reason: existing TS, ... │
        └──────────────────────────┘
User: clicks "React" or says "go with React"
Aura: "Want me to set up the project?" [confirm overlay]
```

**Scenario 3: Voice-Only Cooking**
```
User: "What can I make with what's in my fridge?"
Aura: [no screen context needed]
      "I don't see your fridge, but based on your grocery list
       from yesterday's notes, you have chicken, rice, and bell peppers.
       Three options:"
      [Voice reads: "One: Chicken stir fry. Two: Chicken rice bowl. Three: Stuffed peppers."]
      [Options also appear on screen as cards]
User: "Number two"
Aura: "Chicken rice bowl it is. Want me to walk you through it?"
```

**Scenario 4: Screen Pointing**
```
User: "Where's the logout button?"
Aura: [scans screen]
      [pet moves to upper-right corner]
      [overlay draws pulsing circle around the button]
      "It's in the top right, next to your profile picture."
      [circle fades after 3 seconds]
```
