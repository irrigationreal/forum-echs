# ECHS AGENTS.md

This file is the entry point for AI agents and new contributors working in this
repo. It documents what exists today (code layout + runtime model) and provides
repo-specific "how to work here" guidance.

## TL;DR (Local Commands)

From the umbrella root (`echs/`):

```bash
mix deps.get
mix test
mix format

# Interactive CLI (uses Codex + tool loop)
mix run -e 'EchsCli.main()'
mix run -e 'EchsCli.main(["/path/to/workdir"])'

# Ratatouille TUI
mix run -e 'EchsCli.Tui.main()'
mix run -e 'EchsCli.Tui.main(["/path/to/workdir"])'

# Shortcut script
./bin/echs-tui
./bin/echs-tui /path/to/workdir
```

## What This Repo Is

ECHS = "Elixir Codex Harness Server".

It is an Elixir umbrella that runs a Codex/Responses "tool loop":

1. Send conversation history to the Responses endpoint (streaming SSE).
2. Collect assistant output items.
3. If the assistant produced tool calls, execute them locally.
4. Append tool outputs back into the history.
5. Repeat streaming until the assistant stops calling tools.

This repo provides:

- A runtime (`echs_core`) that manages per-thread state + tool execution.
- A Codex client (`echs_codex`) that handles auth + SSE streaming.
- A simple CLI (`echs_cli`) for manual local runs.
- An HTTP daemon (`echs_server`) exposing a wire API (REST + SSE).
- A persistence layer (`echs_store`) using SQLite (threads/messages/history).
- A protocol app (`echs_protocol`) for shared schemas (includes OpenAPI today).

## Repo Layout

```text
apps/
  echs_core/      Thread runtime, tools, PubSub events, blackboard
  echs_codex/     Auth + streaming client for the responses endpoints
  echs_cli/       Minimal interactive CLI wired to echs_core + echs_codex
  echs_server/    HTTP daemon (REST + SSE) exposing a wire interface
  echs_store/     SQLite persistence (threads/messages/history)
  echs_protocol/  Placeholder for future protocol/schema definitions
config/config.exs Umbrella-wide config (currently minimal)
blackboard.json   Not used by Elixir code in this repo (may be used externally)
```

## Prerequisites / Authentication

This codebase uses the system `codex` CLI for authentication.

- Auth file: `~/.codex/auth.json`
- Initialize/refresh: `codex login`
- Refresh (used by the code): `codex login status`

`EchsCodex.Auth` loads tokens from the auth file and builds request headers:

- `authorization: Bearer <access_token>`
- `chatgpt-account-id: <account_id>`
- `accept: text/event-stream` (streaming endpoint)

If requests return `401`, the client will attempt a refresh and retry once.

## Core Runtime (apps/echs_core)

### Supervision Tree

`EchsCore.Application` starts:

- `Registry` (`EchsCore.Registry`) - maps `thread_id -> pid`
- `DynamicSupervisor` (`EchsCore.ThreadSupervisor`) - supervises `ThreadWorker`
- `Task.Supervisor` (`EchsCore.TaskSupervisor`) - runs streaming tasks
- `EchsCore.Blackboard.Global` - ETS-backed shared KV store
- `EchsCore.Tools.Exec` - session manager (port-backed stdio) for `exec_command`/`write_stdin`
- `Phoenix.PubSub` (`EchsCore.PubSub`) - event bus for threads + blackboard

### Public API

Most callers should use `EchsCore` (a thin wrapper around `EchsCore.ThreadWorker`):

```elixir
{:ok, _} = Application.ensure_all_started(:echs_core)
{:ok, _} = Application.ensure_all_started(:echs_codex)

{:ok, thread_id} = EchsCore.create_thread(cwd: "/path/to/workdir")
{:ok, history} = EchsCore.send_message(thread_id, "Hello from ECHS")
```

Important helpers:

- `EchsCore.send_message/3` - send a message and run a turn
- `EchsCore.queue_message/3` - enqueue if a turn is already running
- `EchsCore.steer_message/3` - preempt (at a safe boundary) if a turn is running
- `EchsCore.configure_thread/2` - hot-swap thread config
- `EchsCore.register_tool/3` - add a per-thread custom tool + handler
- `EchsCore.unsubscribe/1` does not exist; PubSub is caller-managed

### Thread Configuration (create/configure)

`EchsCore.ThreadWorker.create/1` accepts a handful of options worth knowing:

- `:cwd` - thread working directory (defaults to `File.cwd!/0`)
- `:model` - defaults to `gpt-5.2-codex`
- `:reasoning` - defaults to `"medium"` (Codex accepts: `none|minimal|low|medium|high|xhigh`)
- `:instructions` - if omitted, a permissive built-in system prompt is used
- `:tools` - tool specs to expose (defaults to `default_tools/0`)
- `:thread_id` - optional explicit ID (otherwise random `thr_<hex>`)
- `:parent_thread_id` - marks this thread as a child (see blackboard notes)
- `:coordination_mode` - `:hierarchical` (default), `:blackboard`, or `:peer`

Thread configuration can be hot-swapped via:

- `EchsCore.configure_thread(thread_id, config_map)`
- `EchsCore.send_message(thread_id, content, configure: config_map)`

The config map keys supported by the worker today:

- `"cwd"`, `"model"`, `"reasoning"`, `"instructions"`, `"toolsets"`, `"tools"`

Tools can be modified by name using `"+tool"` and `"-tool"` entries. Example:

```elixir
EchsCore.configure_thread(thread_id, %{
  "model" => "gpt-5.2-codex",
  "reasoning" => "high",
  "tools" => ["-apply_patch", "+shell"]
})
```

`"instructions"` supports a literal placeholder `{{cwd}}` which is replaced with
the thread working directory when the worker starts (and when instructions are
updated via config).

### Thread Model (EchsCore.ThreadWorker)

`EchsCore.ThreadWorker` is a GenServer per conversation thread. It stores:

- `history_items` - a list of "Responses API items" (messages, tool calls, etc.)
- `tools` - tool specs exposed to the model
- `tool_handlers` - per-thread custom tool callbacks
- `cwd`, `model`, `reasoning`, `instructions`
- queues for `:queue` and `:steer` messaging when a turn is running

Each turn is executed by:

1. Appending a user "message" item to `history_items`.
2. Starting a streaming request in a supervised Task (`EchsCore.TaskSupervisor`).
3. Receiving SSE events and broadcasting them over PubSub.
4. Collecting completed output items (`response.output_item.done`).
5. Executing any tool calls and appending `function_call_output` items.
6. Restarting streaming until no tool calls remain.

### Data Shapes: Responses Items (What Goes in history_items)

`history_items` is a list of JSON-ish maps shaped like the Responses API:

- `"type": "message"` with `"role": "user" | "assistant"` and `"content": [...]`
- `"type": "function_call"` tool call output item (model -> runtime)
- `"type": "local_shell_call"` local shell tool output item (model -> runtime)
- `"type": "function_call_output"` tool result item (runtime -> model)

This is intentionally close to what the Responses API expects; the worker filters
`history_items` down to these types before calling `EchsCodex.stream_response/1`.

### Turn Control: queue / steer / interrupt / pause

When a thread is already running:

- `mode: :queue` (default) appends a follow-up turn to `queued_turns`.
- `mode: :steer` appends a turn to `steer_queue` and requests stream control.

Stream control boundaries are conservative; interruption/steering is only acted on
after certain SSE event types:

- `response.output_item.done`
- `response.completed`
- `done`

There are also explicit controls:

- `pause_thread/1` - stops streaming and marks the thread paused
- `resume_thread/1` - allows new turns
- `interrupt_thread/1` - stops the current turn at the next safe boundary.
  If the stream task does not respond within 10 seconds (e.g. it is stuck inside
  an HTTP call on a dead socket), the stream task is force-killed and the thread
  recovers automatically. See `@interrupt_force_kill_ms` in `ThreadWorker`.
- `kill_thread/1` - stops the worker and attempts to kill children

### PubSub Events

Each thread broadcasts to topic: `thread:<thread_id>`.

Common events emitted by `EchsCore.ThreadWorker`:

- `:thread_created` - after init
- `:thread_configured` - on configuration updates
- `:turn_started`
- `:turn_delta` - streaming text token deltas
- `:item_started` - when an output item begins
- `:item_completed` - when an output item is finalized
- `:tool_completed` - after local tool execution
- `:turn_completed` - when a turn ends without further tool calls
- `:turn_interrupted` - interrupt/steer/pause boundary reached
- `:turn_error` - streaming/task crash or non-200 response
- `:subagent_spawned` / `:subagent_down`
- `:thread_terminated`

To observe events:

```elixir
:ok = EchsCore.subscribe(thread_id)

receive do
  {:turn_delta, %{content: delta}} -> IO.write(delta)
after
  5_000 -> :timeout
end
```

## Tool Surface (apps/echs_core)

Tools are surfaced to the model via `state.tools` (tool specs). Tool calls are
received as output items and then executed locally.

Built-in tools provided by default (see `EchsCore.ThreadWorker.default_tools/0`):

- `exec_command` - run a command in a session, may return a `session_id`
- `write_stdin` - write to a session and return more output
- `local_shell` - legacy/non-function tool: executes `local_shell_call` items
- `shell` - execute `bash -lc "<command>"` (non-interactive)
- `read_file` - read file with `offset`/`limit`
- `list_dir` - list directory with `depth`/`limit`
- `grep_files` - regex search across paths (simple include/exclude globs)
- `apply_patch` - apply the Codex "*** Begin Patch" format
- `view_image` - attach a local image path to context as an `input_image` (base64 data URL)
- sub-agent tools:
  - `spawn_agent`, `send_to_agent`, `wait_agents`, `kill_agent`
  - `blackboard_write`, `blackboard_read`

### Sub-Agent Model Selection

`spawn_agent` accepts `agent_type`, `model`, and `reasoning` parameters.
`agent_type` controls which model and reasoning level the sub-agent uses:

| agent_type | model          | reasoning | use case                          |
|------------|----------------|-----------|-----------------------------------|
| `default`  | gpt-5.2        | high      | general purpose                   |
| `explorer` | gpt-5.2        | medium    | browsing, searching, exploration  |
| `worker`   | gpt-5.2-codex  | high      | coding tasks                      |
| `research` | gpt-5.2        | high      | deep analysis, complex questions  |
| `simple`   | haiku           | medium    | trivial tasks, quick lookups      |

Resolution order:
1. Explicit `model`/`reasoning` params (highest priority)
2. `agent_type` mapping (if agent_type is specified)
3. Parent thread's model/reasoning (fallback for backward compat)

The mapping is defined in `@subagent_defaults` in
`EchsCore.ThreadWorker.ToolDispatch` and also exposed via
`EchsServer.Models.subagent_recommendations/0`.

Notes:

- `exec_command` and `write_stdin` are implemented by a GenServer
  (`EchsCore.Tools.Exec`) that owns port-backed sessions.
- `exec_command` session IDs are allocated by `EchsCore.Tools.Exec` and currently
  start at `"1000"` and increment per call (useful for tests/logging).
- Outputs are truncated (both by max tokens and by tool implementations).
- `apply_patch` currently supports `*** Add File`, `*** Update File`, and
  `*** Delete File`. It is a best-effort parser (not a full diff engine).

### Patch Format (apply_patch)

`apply_patch` expects the Codex patch format (not unified diff). Minimal example:

```text
*** Begin Patch
*** Update File: path/to/file.txt
@@
-old line
+new line
*** End Patch
```

### Custom Tools

You can add tools per thread with a handler:

```elixir
spec = %{
  "type" => "function",
  "name" => "custom_tool",
  "description" => "Example",
  "parameters" => %{"type" => "object"}
}

handler = fn args, ctx ->
  # ctx contains: %{thread_id: ..., cwd: ..., blackboard: ...}
  {:ok, %{args: args, cwd: ctx.cwd}}
end

:ok = EchsCore.register_tool(thread_id, spec, handler)
```

Handler forms supported (see `EchsCore.ThreadWorker.invoke_tool_handler/3`):

- `fn args, ctx -> ... end`
- `fn args -> ... end`
- `{Mod, :fun}` or `{Mod, :fun, extra_args}` (ctx is passed when available)

## Blackboard (apps/echs_core)

`EchsCore.Blackboard` is an ETS-backed GenServer providing:

- `set/4` and `get/2`
- `watch/3` for process notifications on changes
- `clear/1` and `all/1`

There is a globally registered instance:

- `EchsCore.Blackboard.Global`

`blackboard_write`/`blackboard_read` tool calls currently talk to the global
instance.

Important nuance: `notify_parent` broadcasts a PubSub message to topic
`blackboard`. Every thread subscribes to this topic and filters notifications so
only a parent thread reacts to events coming from its own children.

## Codex Client (apps/echs_codex)

`EchsCodex.Responses` implements:

- `stream_response/1` - POST to the streaming responses endpoint
- `compact/1` - POST to a compaction endpoint (non-streaming)

It uses `Req` with a custom `into:` handler to parse SSE "data: <json>" lines.
If it sees `[DONE]`, it forwards an event `%{"type" => "done"}`.

The URLs are currently hard-coded:

- Streaming: `https://codex.ppflix.net/v1/responses`
- Compact: `https://codex.ppflix.net/v1/responses/compact`

## CLI (apps/echs_cli)

`EchsCli.main/1` is a minimal interactive REPL:

- Starts `:echs_core` and `:echs_codex`.
- Creates a thread with the provided working directory.
- Subscribes to PubSub events and prints streamed deltas + tool activity.

Run it from the umbrella root:

```bash
mix run -e 'EchsCli.main()'
```

## Server / Daemon (apps/echs_server)

`echs_server` is a thin HTTP layer over `echs_core` providing a wire API
(REST + SSE).

Default bind:

- `ECHS_BIND` (default: `0.0.0.0`)
- `ECHS_PORT` (default: `4000`)

Optional auth:

- `ECHS_API_TOKEN` - require `Authorization: Bearer <token>` for all requests

Start locally:

```bash
ECHS_PORT=4000 ECHS_BIND=127.0.0.1 mix run --no-halt -e 'Application.ensure_all_started(:echs_server)'
```

## Protocol (apps/echs_protocol)

This app is intentionally minimal today. Treat it as a placeholder for future
schema/protocol definitions that multiple apps can depend on.

## Repo Hygiene and Working Conventions (for agents)

These are practical rules that match the way this repo is used:

- Work autonomously. Plan internally; implement + validate before reporting back.
- Default cadence: do not send interim progress updates; only report when done.
- Default to working from the umbrella root (`echs/`) unless a task is app-local.
- Prefer `rg` for code search.
- Run `mix test` for changes that touch the runtime/tool loop. Keep tests fast.
- Keep documentation in `README.md` / `apps/*/README.md` / `AGENTS.md`.
- Avoid introducing new runtime dependencies unless required.

### Questions and Defaults

If you must ask a question, keep it to 1 (max 3) and offer options A/B/C with a
recommended default.

If the user does not respond, proceed with the recommended default unless it is
unsafe or destructive.

### Git Safety (especially for agents)

- Do not use destructive git commands (examples: `git reset --hard`).
- If the worktree is already dirty, avoid reverting unrelated local changes.
- If you notice unexpected file changes you did not make, stop and ask.

### Python (only if needed)

This repo is primarily Elixir. If you add a Python helper script anyway:

- Use a local `uv` environment.
- Run commands via `uv run ...`.

### External Tool: cass (agent history search)

If you suspect similar work has been done before, use `cass` to search prior
agent sessions (always use `--robot` or `--json`, never the interactive TUI).

Examples:

```bash
cass search "echs ThreadWorker" --robot --limit 5
cass search "codex auth.json" --robot --limit 5
```
