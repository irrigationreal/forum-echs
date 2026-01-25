# EchsCore

Core runtime for ECHS. Provides thread management, tool execution, PubSub
events, and the shared blackboard used for sub-agent coordination.

## Quickstart

```elixir
{:ok, _} = Application.ensure_all_started(:echs_core)
{:ok, thread_id} = EchsCore.create_thread(cwd: "/path/to/workdir")
EchsCore.send_message(thread_id, "Hello from ECHS")
```

## Queued vs Steer Messages

When a turn is running, you can either queue a follow‑up (default) or steer
the active turn (preempt at a safe boundary):

```elixir
EchsCore.queue_message(thread_id, "Follow up after this turn")
EchsCore.steer_message(thread_id, "Please prioritize error handling")
```

You can also pass `mode: :queue | :steer` directly to `send_message/3`.

## Custom Tools

Register tools per thread so third‑party consumers can expose their own code:

```elixir
spec = %{
  "type" => "function",
  "name" => "custom_tool",
  "description" => "Custom tool",
  "parameters" => %{"type" => "object"}
}

handler = fn args, _ctx -> {:ok, args} end
EchsCore.register_tool(thread_id, spec, handler)
```

## Responsibilities

- `EchsCore.ThreadWorker` — per-thread GenServer that runs the tool loop.
- `EchsCore.Tools` — shell, files, and patch tools.
- `EchsCore.Blackboard` — shared ETS-backed coordination store.
