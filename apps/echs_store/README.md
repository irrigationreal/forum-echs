# EchsStore

SQLite-backed persistence for ECHS.

This app exists so the HTTP daemon (`echs_server`) can survive restarts while
preserving:

- thread metadata (model, reasoning, cwd, instructions, tool surface, etc.)
- per-message metadata/status (queued/running/completed/error)
- append-only thread history items (Responses-style items)

`echs_core` writes to the store opportunistically when it is running; `echs_server`
will restore a thread from the store on-demand when you hit a thread endpoint
for a thread that isn't currently in memory.

## Configuration

The repo uses `Ecto` + `ecto_sqlite3`.

Config lives in the umbrella `config/config.exs` and `config/runtime.exs`.

Runtime env vars (prod releases):

- `ECHS_DB_PATH` - path to the sqlite db file (default: `tmp/echs.db`)
- `ECHS_DB_POOL_SIZE` - DB pool size (default: `5`)
- `ECHS_AUTO_MIGRATE` - `0|false|no` disables auto-migrations at boot

## Tables

The schema is intentionally small and append-only where possible:

- `threads`
  - thread config + `history_count`
- `messages`
  - `status` and timestamps (`queued|running|completed|error|...`)
  - `request_json` (internal payload used to replay queued messages on restore)
- `history_items`
  - `(thread_id, idx)` unique
  - `item` stored as sqlite JSON (`:map` in Ecto)

## Notes

- This is not a general-purpose "chat storage" schema; it's optimized for ECHS'
  internal `history_items` model (Responses API item maps).
- Large `input_image` payloads are intentionally not stored inline by default.
  Use `upload_id` handles; `echs_core` expands them to base64 `data:` URLs only
  when building the API request payload.

