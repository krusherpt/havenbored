# Soundboard → Haven Migration Plan

## 1. Protocol Comparison

### Current: Discord (EDA Library)
```
Soundboard GenServer ──FFmpeg──▶ EDA.Voice (Rust/NIF) ──RTP/Opus──▶ Discord Voice Gateway
         │                                              │
         │                                    Discord Gateway WS (events)
         │                                              │
         ▼                                              ▼
    AudioPlayer, Handler                    Voice state updates, READY event
```

- **Library:** `EDA` (`~> 0.1.3`) — Rust NIF-based Discord client
- **Voice:** EDA.Voice wraps `libwebrtc` (Dave) for RTP/Opus playback
- **Signaling:** Handled internally by EDA (gateway protocol)
- **Channel ID:** Discord `guild_id` + `channel_id` (integer strings)
- **Presence:** EDA.Cache tracks guilds, voice states
- **Commands:** `!join`, `!leave` parsed from Discord messages

### Target: Haven (Webhook API + WebRTC Voice)

**CRITICAL FINDING:** Haven's bot API is **webhook-based only**, not a full bot client.

```
Soundboard GenServer ──HTTP REST──▶ Haven Webhook API ──▶ Haven clients (via Socket.IO)
         │                                              │
         │                                    Webhook callbacks (HMAC-signed)
         │                                              │
         ▼                                              ▼
    AudioPlayer, Handler                    play-sound events, message callbacks
```

- **Bot API:** REST webhooks — `POST /api/webhooks/<token>` for messages, `POST /api/webhooks/<token>/sounds` for sound playback
- **Webhook token:** 64-character hex string
- **Bound to:** A single text channel (webhook has `channel_id`)
- **Rate limit:** 30 requests/minute per IP
- **Callbacks:** Optional `callback_url` with HMAC-SHA256 signature for receiving events

### The Fundamental Problem

**Haven webhooks CANNOT detect voice channel events.** The webhook API is text-channel-bound. There are no webhook events for:
- Users joining/leaving voice channels
- Voice state updates
- Voice channel presence

Haven's voice system is P2P WebRTC between browser/desktop clients. The server only relays signaling. A webhook bot has no voice presence and cannot:
- Join a voice channel
- Play audio directly into a voice channel
- Detect when users are in a voice channel
- Auto-join based on user presence

The webhook API can only:
1. **Send messages** to the webhook's text channel
2. **Play sounds** via `POST /api/webhooks/<token>/sounds` with `{"sound": "name"}` — this emits a `play-sound` Socket.IO event that clients in the text channel hear
3. **Delete messages** in the webhook's channel
4. **Register slash commands** that trigger callbacks
5. **Receive callbacks** for messages, reactions, member joins (if `callback_url` is set)

---

## 2. Architecture Options

### Option A: Webhook-Only (Limited, but works today)

The Soundboard interacts with Haven purely via REST webhooks. No voice detection, no auto-join.

**How it works:**
- Users manually trigger sounds via Slash Commands or a custom `/play` command
- Sound effects play via webhook `POST /api/webhooks/<token>/sounds`
- Users join/leave voice channels manually — no auto-detection
- The Soundboard UI shows which Haven channel the bot is bound to

**What's lost:**
- Auto-join when users are in voice
- Join/leave sound effects (no voice state events)
- Bot presence in voice channels
- Idle timeout / auto-leave

**What's kept:**
- Sound playback (via webhook sound trigger)
- Sound effects (if triggered by slash commands or callbacks)
- Queue management
- UI for browsing/playing sounds
- PubSub for real-time UI updates

**Implementation:** Simple REST calls from Elixir. No WebRTC, no bridge process.

---

### Option B: Webhook + Callback URL (Medium capability)

Use Haven's webhook callback feature to receive events, enabling more automation.

**How it works:**
- Soundboard runs a small HTTP server (Phoenix plug or Elixir GenServer)
- Haven's webhook callbacks POST to `Soundboard/callback/haven`
- Events received: `message`, `reaction-added`, `member-joined`
- Slash commands can trigger sound playback
- Voice join/leave still not available (no webhook event for voice)

**What's gained over Option A:**
- Slash command integration (`/play sound-name`)
- Reaction-based triggers
- Member join/leave events (for text channel members, not voice)
- Two-way communication

**What's still lost:**
- Voice channel detection
- Auto-join voice
- Sound playback in voice channels

---

### Option C: Full Haven Client (Complex, requires Haven protocol reverse-engineering)

Build a full Haven client in Elixir that connects via Socket.IO, similar to how the browser client works.

**How it works:**
- Elixir Socket.IO client connects to Haven server
- Joins voice channels as a real client
- Manages WebRTC peer connections for audio playback
- Receives full voice state events

**What's gained:**
- Full voice channel presence
- Auto-join when users are in voice
- Sound playback directly into voice channels
- Join/leave sound effects
- All Discord features replicated

**What's required:**
- Haven Socket.IO protocol reverse-engineering (not documented)
- WebRTC implementation in Elixir (complex, no mature libraries)
- Significant development effort
- May violate Haven's ToS (unofficial client)

---

## 3. Recommendation

**Start with Option A (Webhook-Only)** as the minimum viable migration. It's straightforward, works with Haven's documented API, and preserves the core soundboard functionality.

**Then evaluate Option B** if slash command integration and callback-based triggers are needed.

**Option C** should only be pursued if the team has time, expertise, and willingness to reverse-engineer Haven's undocumented Socket.IO protocol and implement WebRTC in Elixir.

---

## 4. Detailed Protocol Analysis: Haven Webhook API

### Creating a Webhook (Admin UI)
1. Go to **Settings → Server Admin Settings → Bots**
2. Create webhook with name, optional avatar, optional callback URL
3. Copy the **Webhook Token** (64-character hex string)

### Sending Messages
```
POST https://haven.example.com/api/webhooks/<token>
Content-Type: application/json

{
  "content": "Hello from my bot!",
  "username": "MyBot",
  "avatar_url": "https://example.com/avatar.png",
  "reply_to": 123  // optional: reply to a message
}
```
- `content` required, max 4000 chars
- Response: `{ "success": true, "message_id": 123 }`

### Playing Soundboard Sounds
```
POST https://haven.example.com/api/webhooks/<token>/sounds
Content-Type: application/json

{
  "sound": "AOL - You've Got Mail"
}
```
- `sound` required: exact sound name (case-sensitive)
- Plays for all clients in the webhook's channel
- Response: `{ "success": true }`
- Client receives `play-sound` Socket.IO event

### Listing Sounds
```
GET https://haven.example.com/api/sounds
Authorization: Bearer <user_jwt_token>
```
- Returns list of available sound names
- Requires authenticated user token (not webhook token)

### Deleting Messages
```
DELETE https://haven.example.com/api/webhooks/<token>/messages/<message_id>
```
- Response: `{ "success": true }`

### Slash Commands
```
POST https://haven.example.com/api/webhooks/<token>/commands
{ "command": "leaderboard", "description": "Show leaderboard" }

GET https://haven.example.com/api/webhooks/<token>/commands
DELETE https://haven.example.com/api/webhooks/<token>/commands/leaderboard
```

### Callback Payloads
```
POST <callback_url>
X-Haven-Event: message
X-Haven-Signature: sha256=<hmac>
Content-Type: application/json

{
  "event": "message",
  "channelId": "abcdef01",
  "timestamp": "2025-01-01T00:00:00.000Z",
  "message": {
    "id": 123,
    "content": "Hello",
    "author": { "id": 456, "username": "Alice" },
    "reply_to": null,
    "is_webhook": false,
    "timestamp": "2025-01-01T00:00:00.000Z"
  }
}
```

### Rate Limits
- **30 requests per minute** per IP across all webhook endpoints
- Responses: `{ "error": "Rate limit exceeded" }`

---

## 5. Implementation Plan (Option A: Webhook-Only)

### Phase 1: Haven Webhook Client

**Files to create:**
- `lib/soundboard/haven/webhook_client.ex` — HTTP client for Haven webhook API
- `lib/soundboard/haven/channel.ex` — Haven channel binding (webhook token + channel code)

**Key functions:**
```elixir
defmodule Soundboard.Haven.WebhookClient do
  @spec play_sound(String.t(), String.t()) :: :ok | {:error, reason()}
  def play_sound(webhook_token, sound_name)

  @spec send_message(String.t(), String.t()) :: :ok | {:error, reason()}
  def send_message(webhook_token, text)

  @spec delete_message(String.t(), integer()) :: :ok | {:error, reason()}
  def delete_message(webhook_token, message_id)

  @spec list_sounds(String.t()) :: [String.t()] | {:error, reason()}
  def list_sounds(user_token)

  @spec register_command(String.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def register_command(webhook_token, command, description)
end
```

### Phase 2: Haven Handler (Simplified)

**Files to create:**
- `lib/soundboard/haven/handler.ex` — Event dispatcher (much simpler than Discord version)
- `lib/soundboard/haven/handler/state.ex` — Channel binding state

**What's different from Discord:**
- No voice state tracking (no `voice_states` cache)
- No auto-join logic (no user presence detection)
- No `VoiceRuntime` — just direct REST calls
- Sound effects triggered by callbacks or manual commands

### Phase 3: Audio Player Integration

**Files to modify:**
- `lib/soundboard/audio_player.ex` — Replace `Discord.Voice` calls with `Haven.WebhookClient`
- `lib/soundboard/audio_player/playback_queue.ex` — Simplified (no voice channel state)

**Key changes:**
```elixir
# Before (Discord):
Soundboard.Discord.Voice.play(guild_id, input, type, opts)

# After (Haven):
Soundboard.Haven.WebhookClient.play_sound(webhook_token, sound_name)
```

The audio flow changes fundamentally:
- **Discord:** FFmpeg → EDA.Voice → RTP → Discord Voice Gateway → clients hear it
- **Haven:** Soundboard plays sound → webhook API → `play-sound` event → clients play it via `<audio>` tag

This means the Soundboard doesn't stream audio into Haven's voice channels. Instead, it tells Haven to play a sound file, and Haven's clients play it themselves. The Soundboard's local FFmpeg playback becomes a fallback or parallel path.

### Phase 4: Configuration

**New env vars:**
| Env Var | Purpose |
|---------|---------|
| `HAVEN_SERVER_URL` | Haven server URL |
| `HAVEN_WEBHOOK_TOKEN` | Webhook token (64-char hex) |
| `HAVEN_CHANNEL_CODE` | Text channel code (8-char hex) |
| `HAVEN_CALLBACK_URL` | Optional: callback URL for events |
| `HAVEN_CALLBACK_SECRET` | Optional: HMAC secret for callback verification |
| `HAVEN_USER_TOKEN` | Bearer token for `/api/sounds` listing |

### Phase 5: Application Setup

**Files to modify:**
- `lib/soundboard/application.ex` — Replace Discord children with Haven children
- `config/config.exs` — Haven base config
- `config/runtime.exs` — Haven runtime config
- `mix.exs` — Remove EDA dependency, add HTTP client (e.g., `Tesla` or `Finch`)

---

## 6. Files Affected Summary (Option A)

### Files to Create (6)
```
lib/soundboard/haven/
├── webhook_client.ex
├── channel.ex
├── handler.ex
├── handler.state.ex
test/soundboard/haven/
├── webhook_client_test.exs
├── handler_test.exs
```

### Files to Modify (6)
```
lib/soundboard/application.ex
lib/soundboard/audio_player.ex
lib/soundboard/audio_player/playback_queue.ex
config/config.exs
config/runtime.exs
mix.exs
```

### Files to Delete (11)
```
lib/soundboard/discord/
├── consumer.ex
├── handler.ex
├── handler/
│   ├── auto_join_policy.ex
│   ├── command_handler.ex
│   ├── sound_effects.ex
│   ├── state.ex
│   ├── voice_commands.ex
│   ├── voice_presence.ex
│   └── voice_runtime.ex
├── idle_timeout_policy.ex
├── bot_identity.ex
├── guild_cache.ex
├── runtime_capability.ex
├── voice.ex
```

---

## 7. Risk Assessment

### Low Risk
1. **Webhook API is documented** — Haven provides clear API docs in GUIDE.md
2. **Sound playback works** — `POST /api/webhooks/<token>/sounds` is a simple REST call
3. **No WebRTC complexity** — Option A avoids the Elixir WebRTC problem entirely
4. **Rate limiting is manageable** — 30 req/min is enough for soundboard use

### Medium Risk
5. **No voice detection** — Core Discord feature (auto-join, join sounds) is lost
6. **Sound playback model changed** — Haven plays sounds client-side, not server-streamed
7. **Single channel binding** — Webhook is bound to one text channel, not multiple voice channels

### High Risk
8. **User experience gap** — Discord users expect voice-triggered sounds; Haven users won't have this
9. **ToS concerns** — If Option C is pursued, unofficial clients may violate Haven's terms
10. **Callback reliability** — Haven's webhook callbacks have a 10s timeout and one retry

---

## 8. Implementation Order

1. **Phase 1** — Haven Webhook Client (REST calls, error handling, rate limit awareness)
2. **Phase 2** — Haven Handler (simplified event dispatch, no voice state)
3. **Phase 3** — Audio Player Integration (replace Discord.Voice with Haven.WebhookClient)
4. **Phase 4** — Configuration (env vars, runtime config)
5. **Phase 5** — Application Setup (boot sequence, dependency changes)
6. **Phase 6** — Testing & Cleanup (tests, delete Discord modules)

---

## 9. Decision Point

**Before implementation, you need to decide:**

1. **Option A (Webhook-Only):** Quick, works today, but no voice features. ~2-3 days of work.
2. **Option B (Webhook + Callbacks):** Adds slash commands and event callbacks. ~3-4 days.
3. **Option C (Full Client):** Full feature parity with Discord, but requires Haven Socket.IO protocol reverse-engineering and Elixir WebRTC. ~4-6 weeks, high risk.

The plan above (Option A) is the recommended path forward given Haven's webhook-only bot API.
