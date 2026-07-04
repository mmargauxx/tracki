# Toggl 2.0 (Focus) API — verified notes

Reverse-engineered 2026-07-04 against a live `toggl_sk_` key. The classic Toggl Track
API v9 (`api.track.toggl.com`, HTTP Basic `token:api_token`) and Toggl 2.0 are **separate
APIs with separate keys**. A `toggl_sk_` key is rejected (401/403) by classic v9; a classic
32-hex token does not work on Focus.

## Base + auth
- Base URL: `https://focus.toggl.com/api`
- Auth header: `Authorization: Bearer toggl_sk_...` (NOT Basic auth)
- Key format: `toggl_sk_` + 32 hex chars. One active key per user.

## Endpoints (verified)
| Purpose | Method + path | Notes |
|---|---|---|
| Account id | `GET /accounts/me` | `{ id: "<base62>", user_account_id: <int> }` |
| Current workspace | `GET /users/me/settings` | `{ current_workspace_id: <int>, ... }` |
| Clients | `GET /workspaces/{ws}/clients` | **No org id needed.** `{page,per_page,data:[{id,name,workspace_id,active,...}]}` |
| Projects | `GET /organizations/{org}/workspaces/{ws}/projects` | Org-scoped, paginated (`per_page`, `page`). Project has `id,name,color,client_id,active,workspace_id`. |
| Running timer | `GET /organizations/{org}/workspaces/{ws}/tracking/current` | 200 time entry, or **204** when idle |
| Start timer | `POST /organizations/{org}/workspaces/{ws}/tracking/start` | body `{description,project_id,start(RFC3339),type:"activity"}` |
| Stop timer | `POST /organizations/{org}/workspaces/{ws}/tracking/stop` | body `{end(RFC3339)}` |

Time entry object: `{ id, workspace_id, project_id, description, start, duration, type, ... }`
(`type` ∈ `activity|break`; running entries have negative/zero duration semantics like v9).

## organization_id discovery — the blocker
`organization_id` is a required integer path param for projects + tracking. It is **not
discoverable with an API key**:
- No `me`/`workspaces`/`organizations` list endpoint on `focus.toggl.com/api` accepts the key.
- The shared org API `https://accounts.toggl.com/org/api/organizations` exists but returns
  `401 invalid_jwt_token` for a bearer key — it wants a browser session cookie/JWT.
- Passing a wrong-but-valid-format integer org → `403`; a malformed one → `400 invalid_organization_id`.

**Practical resolution:** the user copies the org id from their logged-in web app URL, or we
expose a manual "Organization ID" field (shown only for `toggl_sk_` keys). Clients still load
without it, so we can partially connect and prompt for the org id to enable projects + timer.

## Swagger source
Full Swagger 2.0 spec: `https://engineering.toggl.com/assets/files/focus-*.json`
(the `focus.json` artifact linked from https://engineering.toggl.com/docs/focus/openapi/).
