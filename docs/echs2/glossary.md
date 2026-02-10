# ECHS 2.0 Glossary

Canonical vocabulary for the ECHS 2.0 system. All code, docs, and protocols
**must** use these terms. Legacy terms are listed for migration reference.

---

## Core Primitives

### Rune
An immutable, typed event record. The atomic unit of the ECHS event model.
Every observable state change produces exactly one rune. Runes are
append-only and never mutated after creation.

- **Legacy term:** history item, event tuple, output item
- **Identifier:** `rune_id` (format: `run_<hex16>`)
- **See also:** Rune Kind, Runelog

### Rune Kind
The discriminator field on a rune that determines its schema and semantics.
Organized into families: `turn.*`, `tool.*`, `agent.*`, `plan.*`,
`memory.*`, `config.*`, `system.*`, `checkpoint.*`.

- **Registry:** `priv/rune_kinds.json`
- **See also:** Rune

### Runelog
The append-only, crash-safe event store. Stores runes as length-prefixed,
CRC32C-checksummed frames in segment files. Provides sequential iteration,
sublinear seek via sparse index, and bounded backfill.

- **Legacy term:** history_items list, SQLite history_items table
- **See also:** Segment, Sparse Index

### Segment
A single Runelog file containing a contiguous range of runes. Segments are
append-only and immutable once sealed (rotated). Active segment receives
new appends.

- **File format:** `<conversation_id>_<start_event_id>.seg`

### Sparse Index
A secondary file mapping every Nth event_id to its byte offset within a
segment. Enables sublinear seek without scanning the entire segment.

- **File format:** `<conversation_id>_<start_event_id>.idx`

---

## Identity & Addressing

### Conversation
A top-level container grouping related turns, agents, and state. Has a
single root agent and an associated runelog. Conversations are the primary
unit of isolation and persistence.

- **Legacy term:** thread (top-level)
- **Identifier:** `conversation_id` (format: `conv_<hex16>`)

### Agent
An autonomous actor within a conversation. Each agent has a role, model
configuration, tool access, and budget. The root agent is created
implicitly with the conversation. Sub-agents are spawned explicitly.

- **Legacy term:** thread (child), sub-agent, ThreadWorker
- **Identifier:** `agent_id` (format: `agt_<hex16>`)

### Turn
A single request-response cycle: user/system input -> model streaming ->
tool execution -> repeat until no more tool calls. Turns are numbered
monotonically within a conversation.

- **Identifier:** `turn_id` (format: `turn_<seq>`)

### Event ID
A monotonically increasing 64-bit integer assigned to each rune on append.
Event IDs are unique within a conversation's runelog and serve as the
primary ordering and resume cursor.

- **Identifier:** `event_id` (uint64)
- **See also:** Runelog, Resume

---

## Turn Engine

### TurnEngine
The state machine governing a single turn's lifecycle. Transitions:
`idle -> streaming -> tool_executing -> streaming -> ... -> completed`.

- **Legacy term:** ThreadWorker turn loop
- **See also:** Turn, StreamRunner

### StreamRunner
The component that executes a single provider API call within a turn.
Receives SSE events, normalizes them to canonical rune kinds, and
publishes via the event pipeline.

- **Legacy term:** `EchsCore.ThreadWorker.StreamRunner`

### Steer
A preemptive message injection during an active turn. Interrupts at
the next safe boundary and injects new user content.

### Queue
A deferred message that waits for the current turn to complete before
starting a new turn.

---

## Provider Layer

### ProviderAdapter
A behaviour defining the interface for LLM provider integrations.
Methods: `start_stream/2`, `cancel/1`. Produces canonical stream events.

- **Implementations:** OpenAI adapter, Anthropic adapter
- **Legacy term:** `EchsCodex.Responses`, `EchsClaude`

### Canonical Stream Event
A normalized event type emitted by all provider adapters:
`assistant_delta`, `assistant_final`, `tool_call`, `usage`, `error`, `done`.

---

## Tool System

### Tool Spec
A canonical tool definition including JSON-Schema parameters and metadata:
`side_effects`, `idempotent`, `streaming`, `requires_approval`, `timeout`,
`max_output_bytes`.

- **Legacy term:** tool definition map in `Config.tool_definitions/1`

### Tool Registry
The runtime registry of available tools per conversation. Tracks
provenance (built-in, remote, MCP), enabled/disabled state, and
per-tool metadata.

### Tool Invocation
The lifecycle of a single tool call: `call` -> `progress`* -> `result`.
Each phase produces a rune. Exactly one terminal result is enforced
(INV-TOOL-TERMINAL).

- **Legacy term:** function_call / function_call_output items

### Approval
A durable permission grant for a tool invocation. Approval modes:
`read_only` (no side effects), `auto` (auto-approve safe tools),
`full_access` (approve everything). Approvals are recorded as runes.

### Permission Policy
A set of rules governing tool execution: workspace scope (allowed paths),
network access (allowlist/denylist), per-tool overrides, approval mode.

---

## Multi-Agent

### AgentTeam
A group of agents within a conversation, managed by an AgentTeamManager.
Supports topologies: hierarchical (default), blackboard, peer.

- **Legacy term:** parent/child ThreadWorkers, Blackboard

### Orchestrator
An agent role that decomposes goals into tasks, assigns them to workers,
and synthesizes results. The default root agent role in autonomy mode.

### Worker
An agent role that executes assigned tasks using tools. Specialized
variants: explorer, critic, summarizer, monitor.

### Plan / Task Graph
A structured decomposition of a goal into tasks with dependencies,
priorities, and ownership. Plans are created and updated via runes,
enabling deterministic replay.

- **Legacy term:** Blackboard key-value entries

### Autonomy Loop
The goal -> plan -> execute -> review cycle. The scheduler assigns tasks
to agents, collects results, runs critique, and determines next steps.
Stop conditions: goal met, budget exhausted, blocked, user interrupt.

---

## Streaming & Distribution

### Event Pipeline
The internal pub/sub system distributing rune notifications to subscribers.
Backed by the runelog (subscribers read from the log, not from fanout
copies). Supports per-conversation topics, bounded buffers, gap signals,
and since_event_id reads.

- **Legacy term:** Phoenix.PubSub + ThreadEventBuffer

### WebSocket Multiplex
The WS endpoint supporting multiple subscriptions per connection.
Operations: subscribe, resume, post_message, approve, interrupt.
Messages are versioned with request_id ACKs and idempotency keys.

### SSE Endpoint
Server-Sent Events streaming with `id=event_id` and `Last-Event-ID`
resume support. Includes server-side backfill with limit and gap event
signaling.

- **Legacy term:** `GET /v1/threads/<id>/events`

### Resume
Reconnecting to a stream using a cursor (event_id for SSE via
Last-Event-ID, or explicit cursor for WS). The server backfills
missed runes without duplicates.

### Gap Signal
An event indicating that the subscriber missed runes between two event_ids
due to buffer overflow or compaction. The client must decide whether to
re-read from the runelog or accept the gap.

---

## Memory

### Memory
A persistent knowledge unit extracted from conversation history. Types:
episodic (what happened), semantic (facts/concepts), procedural
(how-to/patterns), decision (choices made and rationale).

### Memory Candidate
A proposed memory extracted by the post-turn pipeline. Awaits approval
or auto-commit based on policy.

---

## Checkpoints & Rewind

### Checkpoint
A snapshot of workspace state (file tree + conversation position) at a
point in time. Content-addressed, stored outside the runelog. Linked to
tool invocations for "rewind to before this tool call" semantics.

### Rewind
Restoring workspace and/or conversation state to a prior checkpoint.
Modes: workspace-only, conversation-only, both. Transactional (complete
or fail safely).

---

## Visibility

### Visibility
A field on every rune controlling who can see it:
- `public` — visible to all subscribers (API clients, TUI, SDKs)
- `internal` — visible to agents and the event pipeline, hidden from
  external clients
- `secret` — visible only to the originating agent, stripped from all
  external surfaces including internal forwarding

---

## API Surface

### API v2
The ECHS 2.0 wire protocol. REST for CRUD, WebSocket for real-time
streaming, SSE for simple streaming. OpenAPI-documented. Idempotency
keys on mutating operations.

- **Legacy term:** v1 thread/conversation routes in `echs_server/router.ex`

---

## Legacy Term Mapping

| Legacy (v1) | ECHS 2.0 | Notes |
|---|---|---|
| thread | conversation (top-level) or agent (child) | Threads split into two concepts |
| thread_id | conversation_id or agent_id | Depends on context |
| history_item | rune | Typed, immutable, append-only |
| history_items list | runelog | Append-only log, not a list |
| output_item | rune (specific kind) | e.g., turn.assistant_delta |
| function_call | tool.call rune | Canonical tool lifecycle |
| function_call_output | tool.result rune | Terminal result |
| ThreadWorker | TurnEngine + Agent runtime | Split concerns |
| PubSub broadcast | Event pipeline publish | Runelog-backed |
| ThreadEventBuffer | Event pipeline subscriber buffer | With gap handling |
| Blackboard | Plan/Task graph or Agent messaging | Structured alternatives |
| bead | (never used in v1) | Considered, rejected |
