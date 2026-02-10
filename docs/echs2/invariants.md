# ECHS 2.0 Invariants

System-wide correctness invariants. Each invariant has a unique `INV-*`
identifier, a statement, enforcement strategy, and severity.

Severities:
- **FATAL** — Violation indicates data corruption or loss. Halt immediately.
- **ERROR** — Violation indicates incorrect behavior. Log, emit violation rune, alert.
- **WARN** — Violation indicates degraded operation. Log, emit violation rune.

---

## Runelog Invariants

### INV-EVENTID-MONOTONIC
**Event IDs within a conversation's runelog are strictly monotonically increasing.**

- Enforcement: Writer checks `new_event_id > last_event_id` before append.
- Severity: FATAL
- Checked at: Runelog.Writer.append/2

### INV-RUNE-IMMUTABLE
**A rune, once appended to the runelog, is never modified.**

- Enforcement: No update/delete operations exist on the writer. Reader
  validates CRC on read.
- Severity: FATAL
- Checked at: Runelog.Writer (API surface), Runelog.Reader.next/1

### INV-CRC-VALID
**Every rune frame's CRC32C matches its content on read.**

- Enforcement: Reader computes CRC and compares to stored value. Invalid
  frames are reported and skipped (with gap signal).
- Severity: FATAL
- Checked at: Runelog.Reader.next/1

### INV-SEGMENT-CONTIGUOUS
**Segments within a conversation cover a contiguous, non-overlapping range of event IDs.**

- Enforcement: Writer validates start_event_id of new segment ==
  last_event_id of previous segment + 1.
- Severity: FATAL
- Checked at: Runelog.Writer.rotate/1

---

## Turn Engine Invariants

### INV-TURN-SEQUENTIAL
**At most one turn is active per agent at any time.**

- Enforcement: TurnEngine state machine rejects new turn start when
  state != idle.
- Severity: ERROR
- Checked at: TurnEngine.start_turn/2

### INV-TURN-TERMINAL
**Every started turn eventually reaches a terminal state (completed, interrupted, or error).**

- Enforcement: Timeout watchdog (StuckTurnSweeper). Turn start emits
  turn.started rune; terminal state emits turn.completed/interrupted/error
  rune. Watchdog checks for turns without terminal runes after threshold.
- Severity: ERROR
- Checked at: StuckTurnSweeper periodic check

### INV-TURN-ORDER
**Turn IDs within a conversation are monotonically increasing.**

- Enforcement: turn_id = max(existing turn_ids) + 1 on turn start.
- Severity: ERROR
- Checked at: TurnEngine.start_turn/2

---

## Tool Invariants

### INV-TOOL-TERMINAL
**Every tool.call rune is eventually followed by exactly one tool.result rune with the same call_id.**

- Enforcement: ToolRouter tracks pending calls. Timeout produces a
  `tool.result` with status=timeout. Crash produces `tool.result` with
  status=unknown. Duplicate results are rejected.
- Severity: ERROR
- Checked at: ToolRouter.record_result/2, ToolRouter.timeout_check/1

### INV-TOOL-CALL-BEFORE-RESULT
**A tool.result rune must be preceded by a tool.call rune with the same call_id.**

- Enforcement: ToolRouter.record_result/2 looks up pending call. Missing
  call -> violation.
- Severity: ERROR
- Checked at: ToolRouter.record_result/2

### INV-TOOL-APPROVAL-BEFORE-EXEC
**When approval is required for a tool, a tool.approved or tool.denied rune
must precede execution. Denied tools must not execute.**

- Enforcement: PermissionPolicy.check/2 called before dispatch. Approval
  rune emitted before execution. Denied -> tool.result with status=denied.
- Severity: ERROR
- Checked at: ToolRouter.dispatch/2

### INV-TOOL-SANDBOX
**Tool execution must not access paths outside the workspace root or
violate network access rules.**

- Enforcement: ToolContext guard validates paths and network access before
  execution. Violation -> tool.result with status=sandbox_violation.
- Severity: ERROR
- Checked at: ToolContext.validate/2

---

## Agent Invariants

### INV-AGENT-SUPERVISED
**Every agent is supervised by OTP. Agent crash does not propagate to
parent or siblings.**

- Enforcement: DynamicSupervisor with `:temporary` restart strategy per
  agent. Parent monitors child for down signals.
- Severity: ERROR
- Checked at: AgentTeamManager.spawn/2

### INV-AGENT-BUDGET
**An agent must not exceed its configured budget (tokens, tool calls,
wall time).**

- Enforcement: Budget tracker decrements on usage. Exhaustion ->
  agent.budget_exhausted rune, turn termination.
- Severity: WARN
- Checked at: Agent runtime budget check after each provider response

---

## Streaming Invariants

### INV-RESUME-NO-DUPLICATES
**Resuming a stream with a cursor (event_id) must not deliver runes the
client has already received.**

- Enforcement: Server reads from runelog starting at cursor + 1. Event IDs
  are monotonic, so no overlap is possible if the cursor is valid.
- Severity: ERROR
- Checked at: EventPipeline.subscribe/2, SSE resume handler

### INV-RESUME-NO-GAPS
**Resuming a stream must deliver all runes between the cursor and the
current head, or signal a gap if runes have been compacted.**

- Enforcement: If requested cursor < earliest available event_id, emit
  a gap signal rune before backfill.
- Severity: WARN
- Checked at: EventPipeline.subscribe/2

---

## Replay Invariants

### INV-REPLAY-DETERMINISTIC
**Replaying a runelog segment produces identical derived state as the
original live execution (modulo wall-clock timestamps).**

- Enforcement: Snapshot comparison test: take snapshot at event N during
  live execution, replay events 1..N, compare snapshots.
- Severity: ERROR
- Checked at: Gate suite (CI), Runelog.Replay module

### INV-REPLAY-IDEMPOTENT
**Replaying the same runelog segment multiple times produces the same
derived state.**

- Enforcement: Replay test runs N times, asserts identical output.
- Severity: ERROR
- Checked at: Gate suite (CI)

---

## Snapshot & Checkpoint Invariants

### INV-SNAPSHOT-INTEGRITY
**A snapshot's content hash matches its stored hash. Corrupt snapshots
are detected and rejected.**

- Enforcement: Content-addressed storage. Hash verified on read.
- Severity: FATAL
- Checked at: Snapshot.read/1

### INV-CHECKPOINT-RESTORE
**Restoring a checkpoint produces a workspace state byte-identical to
the state at checkpoint creation time.**

- Enforcement: File tree hash comparison after restore.
- Severity: ERROR
- Checked at: Checkpoint.restore/1, Gate suite (CI)

---

## Memory Invariants

### INV-MEMORY-PRIVACY
**Secret-visibility runes are never included in memory extraction input
or memory content.**

- Enforcement: Memory extraction pipeline filters runes by visibility
  before processing.
- Severity: ERROR
- Checked at: MemoryExtractor.extract/2

---

## Summary Table

| ID | Statement (short) | Severity | Enforcement Point |
|---|---|---|---|
| INV-EVENTID-MONOTONIC | Event IDs strictly increasing | FATAL | Runelog.Writer |
| INV-RUNE-IMMUTABLE | Runes never modified | FATAL | Writer API / Reader CRC |
| INV-CRC-VALID | Frame CRC matches content | FATAL | Runelog.Reader |
| INV-SEGMENT-CONTIGUOUS | Segments non-overlapping, contiguous | FATAL | Runelog.Writer |
| INV-TURN-SEQUENTIAL | One active turn per agent | ERROR | TurnEngine |
| INV-TURN-TERMINAL | Every turn reaches terminal state | ERROR | StuckTurnSweeper |
| INV-TURN-ORDER | Turn IDs monotonically increasing | ERROR | TurnEngine |
| INV-TOOL-TERMINAL | Exactly one result per tool call | ERROR | ToolRouter |
| INV-TOOL-CALL-BEFORE-RESULT | Result requires prior call | ERROR | ToolRouter |
| INV-TOOL-APPROVAL-BEFORE-EXEC | Approval before execution | ERROR | ToolRouter |
| INV-TOOL-SANDBOX | Workspace/network containment | ERROR | ToolContext |
| INV-AGENT-SUPERVISED | OTP supervision, crash containment | ERROR | AgentTeamManager |
| INV-AGENT-BUDGET | Budget enforcement | WARN | Agent runtime |
| INV-RESUME-NO-DUPLICATES | No duplicate runes on resume | ERROR | EventPipeline |
| INV-RESUME-NO-GAPS | No silent gaps on resume | WARN | EventPipeline |
| INV-REPLAY-DETERMINISTIC | Replay produces same state | ERROR | Gate suite |
| INV-REPLAY-IDEMPOTENT | Multiple replays produce same state | ERROR | Gate suite |
| INV-SNAPSHOT-INTEGRITY | Snapshot hash valid | FATAL | Snapshot.read |
| INV-CHECKPOINT-RESTORE | Restore is byte-identical | ERROR | Checkpoint.restore |
| INV-MEMORY-PRIVACY | Secret runes excluded from memory | ERROR | MemoryExtractor |
