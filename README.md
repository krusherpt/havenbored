# Havenbored

[![Coverage Status](https://coveralls.io/repos/github/christomitov/soundbored/badge.svg?branch=main)](https://coveralls.io/github/christomitov/soundbored?branch=main)
[![Build Status](https://github.com/krusherpt/soundbored/workflows/CI%2FCD%20Pipeline/badge.svg)](https://github.com/krusherpt/soundbored/actions)

Havenbored is an unlimited, no-cost, self-hosted soundboard for [Haven](https://github.com/ancsemi/Haven). It allows you to play sounds in a Haven text channel via webhook API.

[Hexdocs](https://christomitov.github.io/soundbored/)

<img width="1468" alt="Screenshot 2025-01-18 at 1 26 07 PM" src="https://github.com/user-attachments/assets/4a504100-5ef9-47bc-b406-35b67837e116" />

## Quickstart

1. Copy the sample environment and set the minimum values:
   ```bash
   cp .env.example .env
   # Required for Haven
   HAVEN_SERVER_URL=https://haven.example.com
   HAVEN_WEBHOOK_TOKEN=<your-64-char-hex-token>
   HAVEN_CHANNEL_CODE=<your-8-char-hex-code>
   # Optional: protect the browser UI
   BASIC_AUTH_USERNAME=
   BASIC_AUTH_PASSWORD=
   PHX_HOST=localhost
   SCHEME=http
   ```

2. Run the published container:
   ```bash
   docker run -d -p 4000:4000 --env-file ./.env christom/soundbored
   ```

3. Visit http://localhost:4000, log in with your Haven credentials, and trigger your first sound.

> Create a webhook in Haven: go to **Settings → Server Admin Settings → Bots**, create a webhook, and copy the **Webhook Token** (64-char hex) and **Channel Code** (8-char hex).

## Local Development

```bash
mix setup        # Fetch deps, prepare DB, build assets
mix phx.server   # or iex -S mix phx.server
```

Useful commands:
- `mix test` – run the test suite (coverage via `mix coveralls`).
- `mix credo --strict` – linting.

`docker compose up` also works for a containerized local run; it respects the same `.env` configuration.

## Environment Variables

All available keys live in `.env.example`. Configure the ones that match your setup:

| Variable | Required | Purpose |
| --- | --- | --- |
| `HAVEN_SERVER_URL` | ✔ | Your Haven server URL (e.g. `https://haven.example.com`) |
| `HAVEN_WEBHOOK_TOKEN` | ✔ | 64-character hex webhook token from Haven |
| `HAVEN_CHANNEL_CODE` | ✔ | 8-character hex channel code from Haven |
| `HAVEN_REQUEST_TIMEOUT_MS` | optional | Request timeout in ms. Default: `10000` |
| `BASIC_AUTH_USERNAME` / `BASIC_AUTH_PASSWORD` | optional | Protect the browser UI with HTTP basic auth. API routes stay behind API token auth. |
| `SECRET_KEY_BASE` | ✔ | Signing/encryption secret; generate via `mix phx.gen.secret` or `openssl rand -base64 48`. Takes precedence over `SECRET_KEY_BASE_FILE`.|
| `SECRET_KEY_BASE_FILE` | optional | Path to file containing signing/encryption secret (e.g. for docker secrets). Preferred for security. |
| `PHX_HOST` | ✔ | Hostname the app advertises (`localhost` for local runs). |
| `SCHEME` | ✔ | `http` locally, `https` in production. |

## Deployment

The application is published to Docker Hub as `christom/soundbored`.

### Simple Docker Host

```bash
docker pull christom/soundbored:latest
docker run -d -p 4000:4000 --env-file ./.env christom/soundbored
```

If you place the container behind your own reverse proxy, set `PHX_HOST` and `SCHEME` in `.env` to match the external URL and terminate TLS in your proxy. No additional compose files are required.

## Usage

After creating a webhook in Haven, log in to Havenbored with your Haven username and password. Upload sounds via the web UI or API and trigger them — they will play for all clients in the webhook's channel.

### Sound Playback

Havenbored triggers sounds through Haven's webhook API. When you play a sound:
1. Havenbored sends a `POST /api/webhooks/<token>/sounds` request to Haven
2. Haven broadcasts a `play-sound` Socket.IO event to clients in the channel
3. Haven's clients play the sound via their `<audio>` tags

**Note:** Unlike Discord soundboards, Havenbored does not stream audio directly. Sounds are triggered via the webhook API and played client-side by Haven users.

## API

The API is used to trigger sounds from other applications. Create a personal API token in **Settings** after signing in, then send it as `Authorization: Bearer <USER_API_TOKEN>`.

Current API workflow supports:
- listing sounds
- uploading local files
- creating URL-backed sounds
- queueing playback for a specific sound
- stopping active playback

### Endpoints

#### List sounds
```bash
curl https://havenboredurl.com/api/sounds \
  -H "Authorization: Bearer <USER_API_TOKEN>"
```
Returns `200 OK` with `%{data: [...]}`.

#### Upload a local file
```bash
curl -X POST https://havenboredurl.com/api/sounds \
  -H "Authorization: Bearer <USER_API_TOKEN>" \
  -F "source_type=local" \
  -F "name=wow" \
  -F "file=@/path/to/wow.mp3" \
  -F "tags[]=meme" \
  -F "volume=90"
```
Returns `201 Created` with `%{data: sound}`.

#### Create a URL-backed sound
```bash
curl -X POST https://havenboredurl.com/api/sounds \
  -H "Authorization: Bearer <USER_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"source_type":"url","name":"wow","url":"https://example.com/wow.mp3","tags":["meme","reaction"],"volume":90}'
```
Returns `201 Created` with `%{data: sound}`.

#### Queue playback for a sound
```bash
curl -X POST https://havenboredurl.com/api/sounds/123/play \
  -H "Authorization: Bearer <USER_API_TOKEN>"
```
Returns `202 Accepted` with `%{data: %{status: "accepted", ...}}` because playback is queued asynchronously.

#### Stop active playback
```bash
curl -X POST https://havenboredurl.com/api/sounds/stop \
  -H "Authorization: Bearer <USER_API_TOKEN>"
```
Returns `202 Accepted` with `%{data: %{status: "accepted", ...}}` because the stop request is also asynchronous.

Errors use `%{error: message}` or `%{errors: changeset_errors}` depending on whether the failure is request-level or validation-level.

## Changelog

### v1.8.0 (2026-05-10)

#### ✨ New Features
- **Haven integration**: Migrated from Discord to [Haven](https://github.com/ancsemi/Haven) webhook API.
- **Haven auth**: Login/register with Haven server credentials, including TOTP second-factor support.
- **Webhook-based sound playback**: Sounds triggered via `POST /api/webhooks/<token>/sounds` — no local audio streaming needed.
- **Haven WebhookClient**: Full HTTP client for Haven's webhook API (messages, sounds, commands).
- **Haven AuthClient**: Client for Haven's auth API (login, register, TOTP validation, token verification).

#### ⚙️ Breaking Changes
- Removed all Discord/EDA dependencies (`:eda`, `:rustler`)
- Replaced with `:finch` for HTTP requests
- Removed Discord OAuth — now uses Haven username/password auth
- Removed voice channel management, auto-join, idle timeout (Haven webhooks don't support voice events)
- Changed app name from `:soundboard` to `:havenbored`

#### 🧪 Tests & Quality
- Added tests for Haven webhook client, channel binding, and handler
- Updated all existing tests for new auth flow
- Cleaned up Discord-specific test files

### v1.7.0 (2026-03-07)

#### ✨ New Features
- Switched the Discord voice/runtime integration over to EDA, bringing DAVE support for current Discord voice encryption negotiation.
- Expanded the authenticated API so external tools can list sounds, upload local files, create URL-backed sounds, queue playback, and stop playback with personal user tokens.
- Public URL handling is now centralized so Discord invite/auth links and API examples stay aligned with the configured host and scheme.

#### ⚙️ Improvements
- Audio playback startup is faster and more resilient, reducing common delay/glitch cases during sound playback.
- Voice runtime handling was split into smaller policy/command/presence modules, making Discord connection behavior easier to reason about and maintain.
- Upload and tag persistence flows were consolidated so the LiveView and API paths share the same domain logic.
- The app now boots in a degraded mode when optional voice runtime capabilities are unavailable instead of failing startup entirely.

#### 🧪 Tests & Quality
- Added coverage for command handling, runtime capability detection, public URL behavior, API auth, upload flows, and collaborative sound management rules.
- Clarified the intended collaboration model: any signed-in user can edit shared sound details, but only the original uploader can delete a sound.
- Removed stale dependencies and cleanup scaffolding while continuing the broader code-health refactor.

### v1.6.0 (2025-10-01)

#### ✨ New Features
- New consolidated `Settings` view replaces the standalone API tokens screen and keeps token creation, revocation, and inline API examples in one place.
- Stats dashboard adds a week picker, richer recent activity stream, and refreshed layout under the new name "Stats".
- "Play Random" now respects whatever filters are active, pulling from the current search results or selected tags only.

#### ⚙️ Improvements
- Shared tag components and modal tweaks streamline sound management and reduce layout shifts.
- Navigation highlights the active page and keeps Settings aligned with the rest of the app.
- Mobile refinements across the main board and settings eliminate horizontal scrolling and polish button spacing.
- Basic Auth now quietly skips enforcement when credentials are not configured instead of blocking the UI.

#### 🧪 Tests & Quality
- Expanded LiveView coverage for the new Settings page, Stats interactions, and filtered random playback.
- Updated CI workflow and Dependabot configuration keep coverage and dependency checks automated.

#### 📦 Dependencies
- Bumped Phoenix stack and related dependencies, plus cleaned up mix configuration and docs to match the new release.

### v1.5.0 (2025-09-14)

#### ✨ New Features
- User-scoped API tokens with DB storage (generate/revoke in Settings > API Tokens).
- API requests authenticated via `Authorization: Bearer <token>` are attributed to the token's user and increment stats accordingly.
- In-app API help with copy-to-clipboard curl commands that auto-fill your site URL and token.
- Added Settings link in the navbar for quick access.
- Released a new CLI for easier local and CI integrations.

#### ⚙️ Improvements
- Search bar: reduced debounce to 200ms and added inline spinner while searching.
- Recent Plays: fixed item "disappearing" by using stable DB ids and deterministic ordering; clicked items now bump to the top correctly.

#### 🧪 Tests & Quality
- Added tests for API token lifecycle, API auth with DB tokens, Basic Auth, and the Settings LiveView.
- Coverage improved to ~96% (via mix coveralls).

#### 🔁 Compatibility
- DB-backed personal API tokens are the supported authentication path for API access.

### v1.4.0 (2025-08-22)

#### 🐛 Bug Fixes
- Fixed sounds not playing due to Discord API changes
- Optimized audio playback for faster sound loading and playback

#### 🔧 Maintenance
- Updated all dependencies to latest versions

### v1.3.0 (2025-02-18)

#### ✨ New Features
- Added API to get and trigger sounds.
- Added "stop all sounds" button.
- Implemented auto leave and join voice channels.
- Sorting sounds alphabetically
- Added ability to disable basic auth (just comment out BASIC_AUTH_USERNAME and BASIC_AUTH_PASSWORD in .env)

### v1.2.0 (2025-01-18)

#### ✨ New Features
- Added random sound button.
- Added ability to add and trigger sounds from a URL.
- Allow ability to click tags inside sound Cards for filtering.
- Show what user uploaded a sound in the sound Card.

#### 🐛 Bug Fixes
- Fixed bug where if you uploaded a sound and edited its name before uploading a file it would crash.
- Fixed bug where changing an uploaded sound name created a new sound in entry and didn't update the old.

### v1.1.0 (2025-01-12)

#### ✨ New Features
- Implemented join/leave sound notifications
- Added Discord avatar support for member profiles
- Added week selector functionality to statistics page

#### 🐛 Bug Fixes
- Fixed mobile menu navigation issues on statistics page
- Fixed statistics page not updating in realtime
- Fixed styling issues on stats page
