# Echs

Elixir Codex Harness Server (ECHS). This umbrella hosts the core runtime,
Codex API client, CLI, and protocol surface used by the harness.

ECHS is an Elixir umbrella that runs a Codex/Responses "tool loop":

1. Send conversation history to the Responses endpoint (streaming SSE).
2. Collect assistant output items.
3. If the assistant produced tool calls, execute them locally.
4. Append tool outputs back into the history.
5. Repeat streaming until the assistant stops calling tools.

This repo is meant to be:

- a runnable local harness (CLI) for experimenting with Codex tool-calling, and
- a reusable runtime + client that other Elixir apps can embed.

## Apps (Umbrella)

- `echs_core` — thread runtime, tools, PubSub events, and blackboard.
- `echs_codex` — Codex API auth and streaming client.
- `echs_cli` — interactive CLI for local runs.
- `echs_protocol` — protocol definitions (currently minimal).

## Quickstart (Local)

Prereqs:

- Elixir `~> 1.19` (see `apps/*/mix.exs`)
- `codex` CLI installed and logged in (see Auth section)

From the umbrella root:

```bash
mix deps.get
mix test

# Run an interactive session (uses echs_core + echs_codex under the hood)
mix run -e 'EchsCli.main()'
mix run -e 'EchsCli.main(["/path/to/workdir"])'
```

## Usage (As a Library)

Minimal API usage:

```elixir
{:ok, _} = Application.ensure_all_started(:echs_core)
{:ok, _} = Application.ensure_all_started(:echs_codex)

{:ok, thread_id} = EchsCore.create_thread(cwd: "/path/to/workdir")
{:ok, history_items} = EchsCore.send_message(thread_id, "Hello from ECHS")
```

When a turn is running, you can send follow-ups in two ways:

```elixir
# Queue (default): run after current turn completes
EchsCore.queue_message(thread_id, "Follow up after this turn")

# Steer: preempt at a safe boundary (see Turn Control notes)
EchsCore.steer_message(thread_id, "Please prioritize error handling")
```

## Thread Runtime Model (echs_core)

ECHS runs one `EchsCore.ThreadWorker` GenServer per thread. A "turn" is executed
as:

1. Append the user message into `history_items` (Responses-style items).
2. Start a streaming call via `EchsCodex.stream_response/1`.
3. Broadcast SSE deltas and item boundaries over PubSub.
4. When streaming completes, execute any tool calls the model produced.
5. Append tool outputs to history and continue streaming until the model stops
   calling tools.

### PubSub Events

Each thread broadcasts to topic: `thread:<thread_id>` (via `EchsCore.PubSub`).

Common events:

- `:turn_started`
- `:turn_delta` (streaming text chunks)
- `:item_started` / `:item_completed`
- `:tool_completed`
- `:turn_completed` / `:turn_interrupted` / `:turn_error`

The CLI (`echs_cli`) subscribes and prints these events for you.

## Tools

By default, the thread worker exposes a built-in tool surface to the model,
including:

- Shell execution:
  - `exec_command` / `write_stdin` (port-backed sessions; interactive-ish, not a full TTY)
  - `shell` (simple `bash -lc`, non-interactive)
  - `local_shell` (legacy item type: `local_shell_call`)
- File ops: `read_file`, `list_dir`, `grep_files`
- Patching: `apply_patch` (Codex "*** Begin Patch" format)
- Sub-agents: `spawn_agent`, `send_to_agent`, `wait_agents`, `kill_agent`
- Coordination: `blackboard_write`, `blackboard_read`
- Images: `view_image` (attach a local image path to context as an `input_image`)

### Custom Tools

You can register tools per thread, along with a handler:

```elixir
spec = %{
  "type" => "function",
  "name" => "custom_tool",
  "description" => "Custom tool",
  "parameters" => %{"type" => "object"}
}

handler = fn args, ctx ->
  {:ok, %{args: args, cwd: ctx.cwd}}
end

:ok = EchsCore.register_tool(thread_id, spec, handler)
```

### Sending Images (User Input)

The Responses API supports multi-part message content. In ECHS you can pass a
list of content items instead of a plain string:

```elixir
image_url = "data:image/png;base64,..."  # or https://...

items = [
  %{"type" => "input_text", "text" => "What is in this screenshot?"},
  %{"type" => "input_image", "image_url" => image_url}
]

{:ok, _} = EchsCore.send_message(thread_id, items)
```

## Auth / Codex Client (echs_codex)

ECHS relies on the system `codex` CLI to provision/refresh credentials.

- Auth file: `~/.codex/auth.json`
- Initialize or refresh: `codex login`
- Refresh path used by the code: `codex login status`

The HTTP client uses streaming SSE against a Responses endpoint. The base URLs
are currently hard-coded in `apps/echs_codex/lib/echs_codex/responses.ex`.

## Development

```bash
mix deps.get
mix test
mix format
```

## Notes For AI Agents / Contributors

See `AGENTS.md` for:

- a deeper architectural walkthrough,
- agent-specific working conventions, and
- implementation notes about tools, threading, and blackboard coordination.
