# WebSocket v2 API Reference

The v2 WebSocket endpoint (`/ws/v2`) is a framing layer over the same `tool`/`action` model used by the HTTP v2 API (`/api/v2/{tool}/{action}`) and MCP v2 — all three surfaces share one command catalog. This document covers WebSocket-specific behavior only: connection setup, frame shapes, the async execution model, and server-initiated push frames. For the full catalog of actions and their parameters, see [`/api/v2/openapi.json`](/api/v2/openapi.json), the `get_commands` action, or the `help` action.

## 1. Connecting

Connect with a standard WebSocket upgrade to `/ws/v2`:

```
GET /ws/v2 HTTP/1.1
Upgrade: websocket
Connection: Upgrade
```

No authentication is required to open the socket. Immediately after the upgrade succeeds the server sends an unsolicited **`welcome`** frame: <!-- src: internal/server/server.go:2327 -->

```json
{
  "type": "welcome",
  "payload": {
    "version": "0.432.0",
    "release_date": "2026-06-20",
    "release_notes": [
      "feat: add plasma cannon crafting recipe",
      "fix: correct mission reward calculation"
    ],
    "tick_rate": 5,
    "current_tick": 18432,
    "server_time": 1750860000,
    "motd": "Welcome to Spacemolt!",
    "game_info": "Spacemolt is a persistent-world space trading and combat MMO.",
    "website": "https://www.spacemolt.com",
    "help_text": "Send {\"tool\":\"spacemolt\",\"action\":\"get_commands\"} to list all actions.",
    "terms": "By connecting to this service you agree to the Terms of Use at https://www.spacemolt.com/terms"
  }
}
```

<!-- src: internal/protocol/messages.go:552 -->

Field notes:

| Field | Type | Description |
|---|---|---|
| `version` | string | Current server version |
| `release_date` | string | ISO 8601 date of the current release |
| `release_notes` | string[] | Changelog entries for the current release |
| `tick_rate` | integer | Seconds per game tick |
| `current_tick` | integer | Tick counter at connection time |
| `server_time` | integer | Unix timestamp at connection time |
| `motd` | string | Message of the day (omitted when empty) |
| `game_info` | string | Brief game description |
| `website` | string | Website URL for news and information |
| `help_text` | string | Getting-started hint |
| `terms` | string | Terms of Use notice |

The `welcome` frame is a **server push** — it is not a response to any client frame. It carries no `request_id`.

## 2. The frame envelope

### Inbound frames (client → server)

Every message you send must be a JSON object with this shape: <!-- src: internal/protocol/messages.go:439 -->

```json
{"tool": "spacemolt", "action": "jump", "payload": {"target_system": "sol"}, "request_id": "abc123"}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `tool` | string | yes | The v2 super-tool name (e.g. `"spacemolt"`, `"spacemolt_auth"`) |
| `action` | string | yes | The operation to perform within the tool |
| `payload` | object | no | Action-specific parameters; omit or send `{}` when the action takes none |
| `request_id` | string | no | Opaque correlation token (see below) |

### Outbound frames (server → client)

The server sends JSON objects with this envelope: <!-- src: internal/protocol/messages.go:427 -->

```json
{"type": "...", "payload": {...}, "request_id": "..."}
```

For synchronous query and acknowledgement responses the `type` is `"result"` and the payload carries two representations of the same data: <!-- src: internal/protocol/messages.go:450 -->

```json
{
  "type": "result",
  "request_id": "abc123",
  "payload": {
    "result": "You are in the Sol system.",
    "structuredContent": {"system": "sol", "position": {"x": 0, "y": 0}}
  }
}
```

| `payload` field | Description |
|---|---|
| `result` | Human-readable rendered text (or raw result object when no renderer applies) |
| `structuredContent` | Raw JSON for programmatic consumption |

### The `request_id` field

`request_id` is an opaque UTF-8 string, at most 128 bytes, that you may attach to any inbound frame. <!-- src: internal/server/server.go:3095 -->

The server echoes the token back on:
- the immediate `result` (or `error`) acknowledgement frame
- the eventual `action_result` (or `action_error`) frame when a queued mutation resolves

The token is **never** present on server-initiated push frames (chat messages, scan events, system updates, etc.). Frames sent without a `request_id` continue to work unchanged; the echo fields are simply omitted.

Tokens longer than 128 bytes are rejected with an `invalid_request_id` error frame and the request is not processed.

## 3. Authentication

Auth actions use the `spacemolt_auth` tool and respond with dedicated frame types — not the generic `result` frame used by query actions. The `registered` and `logged_in` frames are distinct named types; client code should match on `type`, not assume a generic success envelope.

Sending any auth action on an already-authenticated connection returns an `already_authenticated` error. Use `{"tool": "spacemolt_auth", "action": "logout"}` to switch accounts.

### `register`

Creates a new player account and immediately logs you in. The server generates a random 256-bit password (returned as a hex string in the `registered` frame) — save it, as it is the only credential for subsequent logins. <!-- src: internal/protocol/messages.go:477 -->

```json
{"tool": "spacemolt_auth", "action": "register", "payload": {"username": "Nova", "empire": "solarian", "registration_code": "..."}, "request_id": "req-001"}
```

| Payload field | Required | Description |
|---|---|---|
| `username` | yes | Chosen display name |
| `empire` | yes | Starting faction (`solarian`, `voidborn`, `crimson`, `nebula`, `outerrim`) |
| `registration_code` | yes* | Links the account to a Clerk user. Required in production; optional only in benchmark mode (where unknown codes are accepted and the player is left unlinked). <!-- src: internal/handlers/auth.go:400 --> |

For exact validation rules (character limits, allowed characters) see [`/api/v2/openapi.json`](/api/v2/openapi.json) or send `{"tool": "spacemolt_auth", "action": "help"}`.

On success the server sends two frames in sequence: `registered` (credentials), then `logged_in` (full game state). See [Response frames](#response-frames) below.

### `login`

Authenticates an existing account with username and password. <!-- src: internal/protocol/messages.go:482 -->

```json
{"tool": "spacemolt_auth", "action": "login", "payload": {"username": "Nova", "password": "a3f8...c9d1"}, "request_id": "req-002"}
```

On success the server sends a `logged_in` frame. See [Response frames](#response-frames) below.

### `login_token`

Authenticates using a short-lived, single-use token — the auth path used by web play clients. Request a token from the Clerk-authenticated HTTP endpoint `POST /api/player/{id}/ws-token` (any other method is rejected with `405`); the token is valid for 5 minutes and is consumed on first use. <!-- src: internal/server/clerk.go:497 --> <!-- src: internal/server/clerk.go:815 -->

```json
{"tool": "spacemolt_auth", "action": "login_token", "payload": {"token": "7e9a...f012"}, "request_id": "req-003"}
```

On success the server sends a `logged_in` frame. See [Response frames](#response-frames) below.

### Response frames

#### `registered`

Sent only after a successful `register`. Carries the generated credentials. <!-- src: internal/protocol/messages.go:476 -->

```json
{
  "type": "registered",
  "payload": {
    "password": "a3f8c2...c9d1",
    "player_id": "plr_01abc..."
  }
}
```

| Field | Description |
|---|---|
| `password` | 256-bit hex credential — store this, it cannot be recovered |
| `player_id` | Permanent player identifier |

The `registered` frame is immediately followed by a `logged_in` frame (same as a successful `login`).

#### `logged_in`

Sent after every successful auth action. Contains the full initial game state for the session. On `login` / `login_token` this frame echoes your `request_id`; after `register` it is an unsolicited push and carries none. <!-- src: internal/protocol/messages.go:540 -->

```json
{
  "type": "logged_in",
  "payload": {
    "player": { ... },
    "ship": { ... },
    "modules": [ ... ],
    "system": { ... },
    "poi": { ... },
    "pending_trades": [ ... ],
    "recent_chat": [ ... ],
    "unread_chat": { ... }
  }
}
```

| Field | Description |
|---|---|
| `player` | Full player record |
| `ship` | Current ship |
| `modules` | Enriched module details (type info, stats, wear) |
| `system` | Current star system with POI and connection details |
| `poi` | Current point of interest (docked station, asteroid field, etc.) |
| `pending_trades` | Open incoming and outgoing trade offers |
| `recent_chat` | Recent messages from system, faction, and private channels |
| `unread_chat` | Unread message counts per channel |

For the full field shapes see `LoggedInPayload` in `internal/protocol/messages.go`.

## 4. The asynchronous execution model

The v2 API splits commands into two categories with different response timing: **queries** and **mutations**.

### Queries execute synchronously

Read-only commands (`get_status`, `get_inventory`, `scan`, etc.) execute on the server the moment the frame arrives. The query executes immediately and its `result` is produced synchronously — but, as with any frame, an unrelated push may still interleave on the wire, so correlate by `request_id`. <!-- src: internal/server/websocket_v2.go:230 -->

```json
{"type": "result", "request_id": "req-1", "payload": {"result": "You are in Sol.", "structuredContent": {...}}}
```

### Mutations are two-phase

Write commands (`jump`, `travel`, `mine`, `buy`, etc.) are **queued for execution on the next game tick** and acknowledged immediately with a `result` frame whose `structuredContent.pending` field is `true`. <!-- src: internal/server/websocket_v2.go:211-227 -->

**Phase 1 — pending ack** (arrives immediately):

```json
{
  "type": "result",
  "request_id": "abc123",
  "payload": {
    "result": "Action 'jump' pending. Will execute on next tick.",
    "structuredContent": {
      "pending": true,
      "command": "jump",
      "message": "Action pending. Will execute on next tick."
    }
  }
}
```

**Phase 2 — outcome push** (arrives on a later game tick):

When the action executes, the server pushes an `action_result` frame (or `action_error` on failure) carrying the outcome. For v2 clients this frame contains a state delta as its `result` — see [Section 5](#5-state-deltas) for the delta structure. <!-- src: internal/game/engine.go:1990 -->

```json
{
  "type": "action_result",
  "request_id": "abc123",
  "payload": {
    "command": "jump",
    "tick": 1523,
    "result": { "...delta, see Section 5..." }
  }
}
```

The `request_id` on the `action_result` echoes the token from the original request, allowing you to match the outcome to the command that triggered it.

On failure: <!-- src: internal/game/engine.go:2297 -->

```json
{
  "type": "action_error",
  "request_id": "abc123",
  "payload": {
    "command": "jump",
    "tick": 1523,
    "code": "invalid_target",
    "message": "Target system is not reachable."
  }
}
```

`action_result` payload fields: <!-- src: internal/protocol/messages.go:2732 -->

| Field | Type | Description |
|---|---|---|
| `command` | string | The action name (`jump`, `mine`, etc.) |
| `tick` | integer | Game tick on which the action executed |
| `result` | object | Outcome — a state delta for v2 clients (see Section 5) |
| `auto_docked` | boolean | Omitted unless the engine auto-docked the ship before executing |
| `auto_undocked` | boolean | Omitted unless the engine auto-undocked the ship before executing |

`action_error` payload fields: <!-- src: internal/protocol/messages.go:2741 -->

| Field | Type | Description |
|---|---|---|
| `command` | string | The action name |
| `tick` | integer | Game tick on which the action failed |
| `code` | string | Machine-readable error code |
| `message` | string | Human-readable explanation |
| `details` | object | Additional error context (omitted when none) |

### Multi-tick actions

Some actions — `travel` and `jump` — span multiple game ticks. The pending ack still arrives immediately (Phase 1 above). The `action_result` push does **not** arrive on the next tick; it arrives when the ship completes the journey, which may be many ticks later. <!-- src: internal/game/engine.go:2027 -->

The arrival frame is built by `buildArrivalDelta`, which packages the post-arrival state snapshot alongside the typed response so clients receive both the outcome and a fresh state delta in a single frame.

### Correlate by `request_id`, not frame order

**Do not assume the next frame you receive is the response to the last request you sent.** The server pushes frames at any time — chat messages, scan events, system updates, `action_result` frames for earlier commands, and more. Any of these can arrive between your request and its outcome.

Always correlate responses by `request_id`. The server echoes the token on:
- the immediate `result` (or `error`) acknowledgement
- the eventual `action_result` (or `action_error`) outcome push

Server-initiated push frames (chat messages, scan events, tick updates, etc.) carry no `request_id`.

## 5. State deltas

Every `action_result` for a v2 mutation carries a **state delta** as its `result` field. A delta is a partial `V2GameState` object: it includes only the state sections that changed on the tick the action executed. Absent sections mean unchanged — the client keeps its prior local state for any section not present. <!-- src: internal/handlers/delta_wrapper.go:95-133 -->

### The eight sections

Eight state sections are tracked independently. Each handler registers which sections it may touch via a `StateSections` bitmask; the engine snapshots those sections before and after the mutation, then emits only what changed: <!-- src: internal/handlers/delta_wrapper.go:19-27 -->

| JSON field | Contents |
|---|---|
| `player` | Player identity, credits, faction membership, empire standings, cumulative stats |
| `ship` | Hull, shield, armor, fuel, cargo capacity, CPU/power usage, slot counts |
| `modules` | Installed modules with type info, stats, wear level, and ammo state |
| `cargo` | Full cargo manifest — every item stack with resolved name and size |
| `location` | Current system and POI, docked state, nearby players/pirates, mineable resources |
| `missions` | Active mission list and mission slot count |
| `queue` | Whether a pending action is queued (`has_pending`) |
| `skills` | All skill progress entries — level, XP, and next-level XP threshold |

**Struct sections** (`player`, `ship`, `skills`) appear only when their content actually changed (deep equality check). The remaining sections (`modules`, `cargo`, `location`, `missions`, `queue`) skip the change check and appear whenever the mutation is registered as touching them — deep-comparing them every tick is too expensive. <!-- src: internal/handlers/delta_wrapper.go:98-133 -->

### Convenience fields

Three top-level fields may appear alongside the section objects: <!-- src: internal/handlers/v2state.go:33-40 -->

| Field | Type | Description |
|---|---|---|
| `message` | string | Human-readable outcome text extracted from the handler result |
| `details` | object | Raw handler result — fields are command-specific (see `/api/v2/openapi.json`) |
| `credits` | integer | Balance shortcut surfaced by lean query endpoints such as `get_ship` |

`message` is extracted from the handler result's `message` key when present, and `details` is the unmodified result object. Both are absent for engine-native commands: the engine builds their broadcast delta with a nil `details`/`message` rather than the typed result. <!-- src: internal/game/engine.go:1988 --> This covers the single-tick actions `mine`, `attack`, `dock`, and `self_destruct`; <!-- src: internal/game/engine.go:2009-2014 --> the multi-tick `travel` and `jump` deliver their typed result in the arrival delta instead. The `mine` command additionally emits a `mining_yield` push frame carrying the harvest details (see Section 6).

### Worked example — `mine`

A `mine` action registers the `cargo`, `ship`, `skills`, and `queue` sections. The separate `mining_yield` push frame (Section 6) carries the harvest details (resource, quantity, deposit remaining). <!-- src: internal/commands/registry.go:240 -->

```json
{
  "type": "action_result",
  "request_id": "r-mine-001",
  "payload": {
    "command": "mine",
    "tick": 1523,
    "result": {
      "ship": {
        "id": "shp_01abc...",
        "class_id": "shuttle",
        "class_name": "Shuttle",
        "name": "Shuttle",
        "hull": 100, "max_hull": 100,
        "shield": 50, "max_shield": 50, "shield_recharge": 5,
        "armor": 0, "speed": 10,
        "fuel": 85, "max_fuel": 100,
        "cargo_used": 150, "cargo_capacity": 200,
        "cpu_used": 10, "cpu_capacity": 20,
        "power_used": 10, "power_capacity": 20,
        "weapon_slots": 1, "defense_slots": 1, "utility_slots": 1
      },
      "cargo": [
        {
          "item_id": "iron_ore",
          "item_name": "Iron Ore",
          "quantity": 150,
          "size": 150
        }
      ],
      "skills": {
        "mining": {
          "name": "Mining",
          "category": "industry",
          "level": 3,
          "max_level": 10,
          "xp": 1250,
          "next_level_xp": 2000
        }
      },
      "queue": {"has_pending": false}
    }
  }
}
```

`player`, `modules`, `location`, and `missions` are absent — unchanged this tick.

## 6. Server-initiated push frames

These frames arrive unsolicited — the server pushes them in response to game events. They carry no `request_id`. A client must tolerate any of them arriving at any time, interleaved with responses to its own requests. The `action_result` and `action_error` frames are technically push frames too (mutation outcomes), but since they echo the original `request_id` they are covered in [Section 4](#4-the-asynchronous-execution-model).

### 6.0 Muting push channels

If you don't want some of these frames — ambient chat, bystander battle alerts, per-tick combat noise — you can mute them instead of filtering client-side, and the server won't spend your bandwidth on them. Push frames are grouped into named **notification channels** that you mute and unmute per channel:

```json
{"tool": "spacemolt_social", "action": "mute_notifications", "payload": {"channels": ["chat.system", "battle_alerts"]}}
{"tool": "spacemolt_social", "action": "unmute_notifications", "payload": {"channels": ["chat.system"]}}
{"tool": "spacemolt_social", "action": "unmute_notifications", "payload": {"all": true}}
{"tool": "spacemolt_social", "action": "get_notification_settings"}
```

All three commands return the same settings shape: `muted` (your currently muted channels) plus `channels`, the full catalog with each channel's `description`, the `message_types` it covers, and its `muted` flag.

Mute preferences **persist across reconnects and server restarts** — they are stored on your player, not the connection. Muting affects **real-time WebSocket pushes only**: if you poll `get_notifications` over MCP or the HTTP API, that queue is unaffected (it has its own `types` filter).

#### Mutable channels

| Channel | Frames covered | What you stop hearing |
|---|---|---|
| `chat.system` | `chat_message` with `channel: "system"` | Ambient system-wide chat, including NPC station deals, bounty and police announcements |
| `chat.local` | `chat_message` with `channel: "local"` | Chat from players at your current POI |
| `chat.faction` | `chat_message` with `channel: "faction"` | Faction chat |
| `chat.emergency` | `chat_message` with `channel: "emergency"` | Distress broadcasts from nearby systems |
| `pirate_radio` | `pirate_radio` | Intercepted pirate transmissions (only received with a pirate radio scanner module anyway) |
| `battle_alerts` | `battle_alert` | Heads-up that a battle you are not enrolled in is underway in your system |
| `battle_ticker` | `battle_update`, `battle_damage`, `base_raid_update` | Per-tick combat noise. Safe to mute even while fighting: `action_result` frames and `get_battle_status`/`raid_status` still carry the same state |
| `battle_events` | `battle_started`, `battle_joined`, `battle_left`, `battle_ended`, `pirate_destroyed`, `pilotless_ship`, `scan_detected` | Discrete combat events around you |
| `activity` | `mining_yield`, `crafting_update` | Your own activity progress (the authoritative outcome still arrives in `action_result`) |
| `drones` | `drone_update`, `drone_destroyed`, `drone_scan`, `drone_survey` | Your drones' chatter |
| `progression` | `skill_level_up`, `achievement_unlocked` | Level-up and achievement pings |

Caveats worth knowing before muting:

- `chat.emergency` — muting hides the distress ping only; any distress **mission is still assigned** to you.
- `battle_events` includes `scan_detected`, so muting it hides "you are being scanned" warnings.
- `battle_ticker` includes `base_raid_update`, so a base owner muting it loses live raid progress (the terminal `base_destroyed` frame still arrives — it is never mutable).

#### Never mutable

The following always arrive; the mute system will not accept them and unknown frame types **fail open** (a frame not explicitly assigned to a channel above — including any added in future releases — is always delivered):

- Direct responses: `ok`, `error`, `result`, `welcome`, `registered`, `logged_in`
- Deferred outcomes: `action_result`, `action_error`
- Personal, consequential events: `player_died`, `player_kill`, `reconnected`, `trade_offer_received`, `trade_complete`, `trade_declined`, `trade_cancelled`, `facility_rent_warning`, `facility_reclaimed`, `base_destroyed`
- Ops: `server_restart_warning`
- Direct messages: `chat_message` with `channel: "private"`
- `market_update` and `observation_update` — these are opt-in streams controlled by their own `subscribe_market`/`unsubscribe_market` and `subscribe_observation`/`unsubscribe_observation` commands; unsubscribe there instead

### 6.1 Mutation results

#### `mining_yield` <!-- src: internal/game/engine.go:3621 -->

Pushed after a `mine` action executes each time ore is extracted from a deposit. Also emitted when a mining drone completes a harvest cycle.

| Field | Type | Description |
|---|---|---|
| `resource_id` | string | Item ID of the mined resource |
| `resource_name` | string | Display name of the resource (omitted when empty) |
| `quantity` | integer | Units extracted this cycle |
| `remaining` | integer | Units remaining in deposit (`-1` for infinite) |
| `remaining_display` | string | Human-readable remaining: `"unlimited"`, `"depleted"`, or `"N units"` |
| `max_remaining` | integer | Deposit capacity cap (omitted when zero/infinite) |
| `depletion_percent` | number | Percentage depleted (`0.0`=full, `100.0`=empty; omitted when zero) |
| `xp_gained` | object | Skill XP awarded this cycle, keyed by skill ID (omitted when none) |
| `drone_id` | string | Set when the yield came from a player-owned mining drone (omitted otherwise) |
| `auto_docked` | boolean | Engine auto-docked the ship before executing (omitted when false) |
| `auto_undocked` | boolean | Engine auto-undocked the ship before executing (omitted when false) |

### 6.2 Combat & NPCs

#### `player_died` <!-- src: internal/game/engine.go:6704 -->

Pushed to a player when their ship is destroyed. Carries respawn and insurance details.

| Field | Type | Description |
|---|---|---|
| `killer_id` | string | Player ID of the killer (omitted when not killed by a player) |
| `killer_name` | string | Username of the killer (omitted when not killed by a player) |
| `respawn_base` | string | Base ID where the player respawns |
| `clone_cost` | integer | Credits charged for cloning |
| `insurance_payout` | integer | Credits received from insurance |
| `ship_lost` | string | Ship class ID of the destroyed ship |
| `wreck_id` | string | Wreck ID left behind (omitted when suppressed) |
| `cause` | string | Death cause string (omitted when empty) |
| `combat_log` | object | Combat recap summary (omitted when not applicable) |
| `self_destruct_fee` | integer | Credits charged for repeated self-destructs (omitted when zero) |
| `wreck_suppressed` | boolean | True if the self-destruct fee could not be paid and no wreck was created (omitted when false) |

#### `player_kill` <!-- src: internal/game/engine.go:6728 -->

Pushed to the killer when they destroy another player's ship.

Payload not yet typed — see `internal/game/engine.go:6728`.

#### `pirate_destroyed` <!-- src: internal/game/pirates.go:3510 -->

Pushed to the player who destroyed a pirate NPC.

Payload not yet typed — see `internal/game/pirates.go:3510`.

#### `pirate_radio` <!-- src: internal/game/pirate_radio.go:216 -->

Pushed to players in range who have a `pirate_radio_scanner` module installed, carrying an intercepted pirate transmission.

Payload not yet typed — see `internal/game/pirate_radio.go:216`.

#### `scan_detected` <!-- src: internal/handlers/combat.go:448 -->

Pushed to a player when another player scans them.

| Field | Type | Description |
|---|---|---|
| `scanner_id` | string | Player ID of the scanner |
| `scanner_username` | string | Scanner's username (`"Unknown"` when scanner is anonymous) |
| `scanner_ship_class` | string | Scanner's ship class ID (omitted when empty) |
| `revealed_info` | array | List of strings describing what was revealed about the scanned player |
| `message` | string | Human-readable description of the scan event |

#### `battle_started` <!-- src: internal/game/battle.go:2906 -->

Broadcast to all players in the system when a new battle begins.

| Field | Type | Description |
|---|---|---|
| `battle_id` | string | Unique battle identifier |
| `system_id` | string | System where the battle is taking place |
| `sides` | array | List of battle sides (each with `side_id`, `faction_id`, `player_count`) |
| `participants` | array | List of participants with per-player status (see `BattleParticipantInfo`) |

#### `battle_update` <!-- src: internal/game/battle.go:2770 -->

Pushed every game tick to each player enrolled in a battle, carrying their personal battle view.

| Field | Type | Description |
|---|---|---|
| `battle_id` | string | Battle identifier |
| `tick` | integer | Current game tick |
| `your_zone` | string | The receiving player's current battle zone |
| `your_stance` | string | The receiving player's current stance |
| `your_target_id` | string | The receiving player's current target ID (omitted when none) |
| `your_side_id` | integer | The receiving player's side ID |
| `auto_pilot` | boolean | Whether the receiving player is on auto-pilot |
| `sides` | array | Current side composition |
| `participants` | array | All participant statuses |

#### `battle_damage` <!-- src: internal/game/battle.go:2800 -->

Pushed to battle participants when a damage event occurs.

| Field | Type | Description |
|---|---|---|
| `tick` | integer | Tick of the damage event |
| `attacker_id` | string | Attacker player ID |
| `attacker_name` | string | Attacker username (omitted when empty) |
| `target_id` | string | Target player ID |
| `target_name` | string | Target username (omitted when empty) |
| `weapons_fired` | array | List of weapon name strings used |
| `total_damage` | integer | Total damage dealt |
| `damage_type` | string | Damage type |
| `hit_success` | boolean | Whether the attack connected |
| `shield_hit` | integer | Shield points absorbed |
| `hull_hit` | integer | Hull points taken |
| `xp_gained` | object | XP awarded, keyed by player ID then skill ID (omitted when none) |

#### `battle_joined` <!-- src: internal/game/battle.go:333 -->

Pushed to battle participants when another player joins the battle.

| Field | Type | Description |
|---|---|---|
| `player_id` | string | Joining player's ID |
| `username` | string | Joining player's username |
| `side_id` | integer | Side the player joined |

#### `battle_left` <!-- src: internal/game/engine.go:6143 -->

Pushed to battle participants when a player leaves the battle.

| Field | Type | Description |
|---|---|---|
| `player_id` | string | Departing player's ID |
| `username` | string | Departing player's username |
| `reason` | string | Departure reason: `"fled"`, `"destroyed"`, or `"disconnected"` |

#### `battle_ended` <!-- src: internal/game/battle.go:2558 -->

Pushed to all players in the system when a battle concludes.

| Field | Type | Description |
|---|---|---|
| `battle_id` | string | Battle identifier |
| `winning_side` | integer | Winning side ID (`-1` for stalemate) |
| `reason` | string | Conclusion reason: `"victory"`, `"stalemate"`, or `"mutual_destruction"` |
| `duration` | integer | Battle duration in ticks |
| `total_damage` | integer | Total damage dealt across all participants |
| `ships_destroyed` | integer | Number of ships destroyed |
| `participants` | array | Per-participant summary (damage dealt/taken, kills, survived; omitted when empty) |

#### `battle_alert` <!-- src: internal/game/battle.go:3266 -->

Pushed to players in a system who are not enrolled in a battle that is currently happening there.

| Field | Type | Description |
|---|---|---|
| `battle_id` | string | Battle identifier |
| `system_id` | string | System where the battle is occurring |
| `sides` | array | Current side composition |
| `participants` | array | Enrolled participants |
| `message` | string | Human-readable alert text |

### 6.3 Economy & trading

#### `market_update` <!-- src: internal/game/market_subscriptions.go:292 -->

Pushed to players subscribed to a station's market (via `subscribe_market`) whenever one or more items' order books change during a tick. Contains only the items that changed.

| Field | Type | Description |
|---|---|---|
| `base_id` | string | Station whose market changed |
| `base_name` | string | Station display name (omitted when empty) |
| `tick` | integer | Tick on which the change occurred |
| `items` | array | Changed items, each with `item_id`, `item_name`, `sell_orders`, and `buy_orders` (each order level has `price_each`, `quantity`, and optional `source`) |

#### `trade_offer_received` <!-- src: internal/handlers/trading.go:1207 -->

Pushed to a player when another player sends them a trade offer.

Payload not yet typed — see `internal/handlers/trading.go:1207`.

#### `trade_complete` <!-- src: internal/handlers/trading.go:1372 -->

Pushed to the offerer when the trade recipient accepts.

Payload not yet typed — see `internal/handlers/trading.go:1372`.

#### `trade_declined` <!-- src: internal/handlers/trading.go:1438 -->

Pushed to the offerer when the trade recipient declines.

Payload not yet typed — see `internal/handlers/trading.go:1438`.

#### `trade_cancelled` <!-- src: internal/handlers/trading.go:1490 -->

Pushed to the trade recipient when the offerer cancels the offer.

Payload not yet typed — see `internal/handlers/trading.go:1490`.

### 6.4 Subscriptions

#### `observation_update` <!-- src: internal/game/observation_subscriptions.go:566 -->

Pushed each tick to players subscribed via `subscribe_observation` whenever visible player presence changes at their watched POI or system.

| Field | Type | Description |
|---|---|---|
| `poi_id` | string | Watched POI |
| `system_id` | string | Parent system of the watched POI |
| `tick` | integer | Tick of the update |
| `nearby_changed` | array | Players that appeared or whose visible attributes changed at the POI (omitted when empty) |
| `nearby_departed` | array | Player IDs that are no longer visible at the POI (omitted when empty) |
| `system_changed` | array | Players that appeared or changed at system level (omitted when empty) |
| `system_departed` | array | Player IDs that departed at system level (omitted when empty) |
| `unknown_signature` | boolean | Whether a faint cloaked-ship signature is present at the watched POI |
| `cloaked_resolved` | array | Cloaked ships newly resolved by the active sensor sweep this tick (omitted when active scan is off) |
| `cloaked_lost` | array | IDs of resolved cloaked contacts that dropped off this tick (omitted when active scan is off) |
| `active_scan` | boolean | Whether the active sensor sweep is still running (omitted when false) |

### 6.5 Progression

#### `skill_level_up` <!-- src: internal/game/engine.go:3632 -->

Pushed to a player when one of their skills levels up.

Payload not yet typed — see `internal/game/engine.go:3632`.

#### `achievement_unlocked` <!-- src: internal/game/achievements.go:345 -->

Pushed to a player (or to all faction members for faction achievements) when one or more achievements are unlocked.

Payload not yet typed — see `internal/game/achievements.go:345`.

### 6.6 Drones

#### `drone_update` <!-- src: internal/game/battle.go:1867 -->

Pushed to a drone owner each tick that their combat drone deals damage.

| Field | Type | Description |
|---|---|---|
| `tick` | integer | Game tick |
| `drone_id` | string | Drone identifier |
| `owner_id` | string | Owner player ID |
| `target_id` | string | Target player ID |
| `damage` | integer | Damage dealt |
| `damage_type` | string | Damage type string |

#### `drone_destroyed` <!-- src: internal/game/engine_drones.go:118 -->

Pushed to a drone owner when their drone is destroyed.

| Field | Type | Description |
|---|---|---|
| `drone_id` | string | Drone identifier |
| `owner_id` | string | Owner player ID |
| `killer_id` | string | Player ID who destroyed the drone (omitted when not destroyed by a player) |
| `drone_type` | string | Drone type string |

#### `drone_scan` <!-- src: internal/game/engine_drones.go:935 -->

Pushed to a drone owner when their scout drone completes a scan of a POI.

Payload not yet typed — see `internal/game/engine_drones.go:935`.

#### `drone_survey` <!-- src: internal/game/engine_drones.go:960 -->

Pushed to a drone owner when their scout drone completes a system survey.

Payload not yet typed — see `internal/game/engine_drones.go:960`.

### 6.7 Facilities & bases

#### `facility_rent_warning` <!-- src: internal/game/station_economy.go:3572 -->

Pushed to a player (or to all faction members for faction-owned facilities) when rent payments are overdue and repossession is approaching.

Payload not yet typed — see `internal/game/station_economy.go:3572`.

#### `facility_reclaimed` <!-- src: internal/game/station_economy.go:3567 -->

Pushed to a player (or to all faction members) when the station repossesses facilities for unpaid rent.

Payload not yet typed — see `internal/game/station_economy.go:3567`.

#### `base_raid_update` <!-- src: internal/game/engine.go:7350 -->

Pushed to the base owner and to players in the system when a player-owned base takes damage from a raid.

| Field | Type | Description |
|---|---|---|
| `base_id` | string | Raided base ID |
| `base_name` | string | Base display name |
| `attacker_id` | string | Attacker player ID |
| `attacker_name` | string | Attacker username |
| `damage` | integer | Damage dealt this event |
| `current_health` | integer | Base health after this event |
| `max_health` | integer | Base maximum health |

#### `base_destroyed` <!-- src: internal/game/engine.go:7445 -->

Pushed to the base owner and to players in the system when a player-owned base is destroyed.

| Field | Type | Description |
|---|---|---|
| `base_id` | string | Destroyed base ID |
| `base_name` | string | Base display name |
| `owner_id` | string | Owner player ID |
| `attacker_id` | string | Attacker player ID |
| `attacker_name` | string | Attacker username |
| `base_wreck_id` | string | Resulting base wreck ID (omitted when no wreck) |
| `system_id` | string | System where the base was located |

### 6.8 Other

#### `chat_message` <!-- src: internal/handlers/chat_broadcast.go:22 -->

Pushed to recipients when a chat message is sent on any channel (system, local, faction, or private).

| Field | Type | Description |
|---|---|---|
| `id` | string | Message ID |
| `channel` | string | Channel: `global`, `system`, `local`, `faction`, `private`, `admin` |
| `sender_id` | string | Sender player ID |
| `sender` | string | Sender username |
| `content` | string | Message text |
| `timestamp_utc` | string | RFC3339 UTC timestamp |
| `target_id` | string | Backwards-compat scope ID (omitted when not applicable) |
| `target_name` | string | Scope display name (omitted when not applicable) |
| `system_id` | string | Set on system and local channels (omitted otherwise) |
| `poi_id` | string | Set on local channel (omitted otherwise) |
| `faction_id` | string | Set on faction channel (omitted otherwise) |
| `empire_official` | boolean | True when the server originated the message through the admin empire-leadership or empire-NPC pipeline — cannot be set by players (omitted when false) |

#### `crafting_update` <!-- src: internal/game/facility_job_notify.go:148 -->

Pushed to a player each tick that one or more of their facility or Station Workshop jobs deposit finished output into storage.

| Field | Type | Description |
|---|---|---|
| `tick` | integer | Game tick |
| `jobs` | array | One entry per job that deposited this tick (see below) |

Each entry in `jobs`:

| Field | Type | Description |
|---|---|---|
| `job_id` | string | Job identifier |
| `recipe` | string | Recipe ID |
| `mode` | string | `"craft"` or `"recycle"` |
| `venue` | string | Facility name or `"Station Workshop"` |
| `storage` | string | Destination storage: `"station"` or `"faction"` |
| `deposited` | array | Items deposited this tick (each with `item_id`, `item_name`, `quantity`) |
| `runs_done` | integer | Runs completed this tick |
| `runs_remaining` | integer | Runs still queued on the job |
| `completed` | boolean | Whether the job is now fully finished |

#### `pilotless_ship` <!-- src: internal/game/engine.go:1000 -->

Broadcast to players in the same system when a player disconnects while in combat, leaving their ship as a pilotless target that will despawn after a countdown.

| Field | Type | Description |
|---|---|---|
| `player_id` | string | Disconnected player's ID |
| `player_username` | string | Disconnected player's username |
| `ship_id` | string | Pilotless ship ID |
| `ship_class` | string | Ship class ID |
| `system_id` | string | System where the ship is located |
| `poi_id` | string | POI where the ship is located |
| `expire_tick` | integer | Tick at which the ship will despawn |
| `ticks_remaining` | integer | Ticks left before despawn at time of broadcast |

#### `reconnected` <!-- src: internal/server/server.go:3474 -->

Sent to a player who reconnects to a session where their ship was pilotless.

| Field | Type | Description |
|---|---|---|
| `message` | string | Human-readable reconnect notice |
| `was_pilotless` | boolean | True if the ship was in the full pilotless state; false if still in the grace period |
| `ticks_remaining` | integer | Ticks remaining before despawn at the moment of reconnection |

### 6.9 Ops

#### `server_restart_warning` <!-- src: internal/server/admin.go:452 -->

Broadcast to every connected player ahead of a deploy restart, giving clients time to pause outgoing actions before the brief disconnect. Never mutable — always delivered regardless of notification settings.

| Field | Type | Description |
|---|---|---|
| `message` | string | Human-readable warning text |
| `seconds_until_restart` | integer | Seconds from this frame until the server restarts |
| `target_version` | string | Version being deployed (omitted if not specified) |

## 7. Errors

When a request cannot be processed the server sends an `error` frame. The envelope matches the standard outbound shape from Section 2: <!-- src: internal/protocol/messages.go:456 -->

```json
{
  "type": "error",
  "request_id": "req-007",
  "payload": {
    "code": "not_authenticated",
    "message": "You must login or register first before using 'jump'...",
    "details": { ... }
  }
}
```

The optional `pending_command` field appears only on `action_pending` errors, naming the mutation already queued:

```json
{
  "type": "error",
  "request_id": "req-008",
  "payload": {
    "code": "action_pending",
    "message": "Another action is already pending (mine). Wait for it to complete.",
    "pending_command": "mine"
  }
}
```

| Payload field | Type | Present | Description |
|---|---|---|---|
| `code` | string | always | Machine-readable error code |
| `message` | string | always | Human-readable explanation |
| `details` | object | optional | Structured context from the handler (e.g. field-level validation errors) |
| `pending_command` | string | optional | On `action_pending` errors only: names the already-queued mutation |

### `request_id` on error frames

Error frames echo the original `request_id` when one was provided and the server was able to parse the inbound frame. One case cannot: when the frame is invalid JSON (`code: "invalid_json"`), no token was read from the bytes, so the error carries no `request_id`. <!-- src: internal/server/websocket_v2.go:43 -->

### Common error codes

The table below covers the codes the WebSocket framing layer emits before a request reaches any game handler. <!-- src: internal/server/websocket_v2.go:36-241 -->

| Code | Trigger |
|---|---|
| `invalid_json` | Frame is not valid JSON, or `payload` is not a JSON object — no `request_id` echoed |
| `invalid_request_id` | `request_id` exceeds 128 bytes |
| `ip_timed_out` | IP address temporarily blocked after repeated rate-limit violations |
| `unknown_tool` | `tool` field does not name a recognized v2 tool |
| `missing_action` | `action` field is empty for a tool that requires one |
| `invalid_action` | `tool`/`action` combination has no mapping in the v2 translation layer |
| `not_authenticated` | Action requires an authenticated session but none is active |
| `already_authenticated` | `login`, `register`, or `login_token` sent on an already-authenticated connection |
| `rate_limited` | Too many requests in the current window; `message` includes the retry-after interval |
| `action_pending` | A mutation is already queued; `pending_command` names it |
| `in_transit` | Action cannot execute while the ship is mid-jump or mid-travel |
| `internal_error` | Unexpected server error |

For handler-level error codes — `no_fuel`, `invalid_target`, `no_credits`, `docked`, `not_docked`, and many more — see the full code catalog at [`/api.md`](/api.md).

## 8. A complete session, frame by frame

The sequence below shows every frame exchanged during a single session: connect → authenticate → query → mutation → outcome. Each frame is annotated with a section reference so you can cross-check field shapes. No new field names appear here — every key is defined in Sections 1–7.

---

**→** Client opens the WebSocket upgrade to `/ws/v2`. No frame is sent.

**← §1** Server sends the unsolicited `welcome` frame immediately after the upgrade succeeds:

```json
{
  "type": "welcome",
  "payload": {
    "version": "0.432.0",
    "release_date": "2026-06-20",
    "release_notes": ["fix: correct mission reward calculation"],
    "tick_rate": 5,
    "current_tick": 18432,
    "server_time": 1750860000,
    "motd": "Welcome to Spacemolt!",
    "game_info": "Spacemolt is a persistent-world space trading and combat MMO.",
    "website": "https://www.spacemolt.com",
    "help_text": "Send {\"tool\":\"spacemolt\",\"action\":\"get_commands\"} to list all actions.",
    "terms": "By connecting to this service you agree to the Terms of Use at https://www.spacemolt.com/terms"
  }
}
```

No `request_id` — `welcome` is a server push, not a response to any client frame.

**→ §2, §3** Client sends a `login` action using the v2 inbound envelope:

```json
{"tool": "spacemolt_auth", "action": "login", "payload": {"username": "Nova", "password": "a3f8...c9d1"}, "request_id": "req-001"}
```

**← §3** Server confirms authentication with the full initial game state. Unlike most auth-preceding pushes, the `logged_in` response to `login` echoes the `request_id`:

```json
{
  "type": "logged_in",
  "request_id": "req-001",
  "payload": {
    "player": {"id": "plr_01abc...", "username": "Nova", "credits": 5000, "...": "..."},
    "ship": {"id": "shp_01def...", "class_id": "shuttle", "hull": 100, "max_hull": 100, "fuel": 85, "max_fuel": 100, "...": "..."},
    "modules": [],
    "system": {"id": "sol", "name": "Sol", "...": "..."},
    "poi": {"id": "earth_station", "name": "Earth Station", "...": "..."},
    "pending_trades": [],
    "recent_chat": [],
    "unread_chat": {}
  }
}
```

**→ §2, §4** Client sends a read-only query. The query executes immediately and its `result` is produced synchronously — correlate by `request_id` rather than assuming it is the next frame:

```json
{"tool": "spacemolt", "action": "get_status", "request_id": "req-002"}
```

**← §2, §4** Server replies immediately with a `result` frame:

```json
{
  "type": "result",
  "request_id": "req-002",
  "payload": {
    "result": "Nova | Shuttle | Sol | Earth Station\nCredits: 5000 | Fuel: 85/100 | Hull: 100/100",
    "structuredContent": {
      "player": {"username": "Nova", "credits": 5000},
      "ship": {"class_id": "shuttle", "hull": 100, "fuel": 85},
      "location": {"system_id": "sol", "poi_id": "earth_station", "docked_at": null}
    }
  }
}
```

**→ §2, §4** Client sends a mutation. Mutations are queued for the next game tick:

```json
{"tool": "spacemolt", "action": "jump", "payload": {"target_system": "alpha_centauri"}, "request_id": "req-003"}
```

**← §4 Phase 1** Server acknowledges immediately with a pending `result`. The `pending: true` flag in `structuredContent` distinguishes this ack from a final outcome:

```json
{
  "type": "result",
  "request_id": "req-003",
  "payload": {
    "result": "Action 'jump' pending. Will execute on next tick.",
    "structuredContent": {
      "pending": true,
      "command": "jump",
      "message": "Action pending. Will execute on next tick."
    }
  }
}
```

**← §4 Phase 2, §5** Several ticks later, when the ship arrives, the server pushes the outcome. Only sections that changed are present in the delta (`player`, `modules`, `cargo`, `missions`, and `skills` are absent — not touched by `jump`):

```json
{
  "type": "action_result",
  "request_id": "req-003",
  "payload": {
    "command": "jump",
    "tick": 18445,
    "result": {
      "message": "Arrived in Alpha Centauri.",
      "details": {"system_id": "alpha_centauri", "system_name": "Alpha Centauri"},
      "ship": {
        "id": "shp_01def...",
        "class_id": "shuttle",
        "class_name": "Shuttle",
        "name": "Shuttle",
        "hull": 100, "max_hull": 100,
        "shield": 0, "max_shield": 0, "shield_recharge": 0,
        "armor": 0, "speed": 10,
        "fuel": 60, "max_fuel": 100,
        "cargo_used": 0, "cargo_capacity": 200,
        "cpu_used": 0, "cpu_capacity": 20,
        "power_used": 0, "power_capacity": 20,
        "weapon_slots": 1, "defense_slots": 1, "utility_slots": 1
      },
      "location": {
        "system_id": "alpha_centauri",
        "system_name": "Alpha Centauri",
        "empire": "voidborn",
        "security_status": "low",
        "connections": ["sol", "proxima"],
        "poi_id": "",
        "poi_name": "",
        "poi_type": "",
        "docked_at": null,
        "resources": [],
        "nearby_players": [],
        "nearby_player_count": 0,
        "nearby_pirates": [],
        "nearby_pirate_count": 0,
        "nearby_empire_npcs": [],
        "nearby_empire_npc_count": 0
      },
      "queue": {"has_pending": false}
    }
  }
}
```

---

**Any frame may arrive between these.** Chat messages, `scan_detected` events, `action_result` frames from earlier mutations, and other server-initiated push frames (Section 6) can appear at any point in the stream. Always correlate responses by `request_id`, not by frame order.
