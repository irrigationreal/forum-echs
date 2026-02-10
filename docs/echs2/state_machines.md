# ECHS 2.0 State Machines

Formal state machine definitions for core ECHS 2.0 subsystems. All
diagrams use Mermaid syntax and render on GitHub.

---

## TurnEngine State Machine

Governs the lifecycle of a single turn within an agent.

```mermaid
stateDiagram-v2
    [*] --> idle

    idle --> streaming : start_turn(input)
    streaming --> tool_executing : tool_calls_received
    streaming --> completed : response_done(no_tool_calls)
    streaming --> interrupted : interrupt / steer
    streaming --> error : stream_error

    tool_executing --> streaming : tools_finished(continue)
    tool_executing --> completed : tools_finished(no_more_calls)
    tool_executing --> interrupted : interrupt
    tool_executing --> error : tool_crash(unrecoverable)

    interrupted --> idle : turn_finalized
    completed --> idle : turn_finalized
    error --> idle : turn_finalized

    note right of streaming
        StreamRunner executes provider API call.
        Emits turn.assistant_delta runes.
        Polls for stream control (interrupt/steer).
    end note

    note right of tool_executing
        ToolRouter dispatches tool calls.
        Emits tool.call, tool.progress, tool.result runes.
        Parallel-safe tools run concurrently.
    end note

    note right of interrupted
        Current work is stopped at safe boundary.
        Partial results preserved as runes.
        Steer injects new input for next turn.
    end note
```

### Turn Events (Rune Kinds)

| Transition | Rune Kind | Payload |
|---|---|---|
| idle -> streaming | `turn.started` | turn_id, agent_id, input |
| streaming (delta) | `turn.assistant_delta` | content fragment |
| streaming -> tool_executing | `turn.tool_calls_received` | [call_ids] |
| streaming -> completed | `turn.completed` | final_output, usage |
| streaming -> interrupted | `turn.interrupted` | reason, partial_output |
| streaming -> error | `turn.error` | error_type, message |
| tool_executing -> streaming | `turn.tools_finished` | [result summaries] |
| completed -> idle | (internal, no rune) | |
| error -> idle | (internal, no rune) | |

---

## Tool Lifecycle State Machine

Governs a single tool invocation from call to terminal result.

```mermaid
stateDiagram-v2
    [*] --> pending_call

    pending_call --> awaiting_approval : requires_approval
    pending_call --> executing : auto_approved / no_approval_needed

    awaiting_approval --> executing : approved
    awaiting_approval --> denied : denied
    awaiting_approval --> timeout_result : approval_timeout

    executing --> executing : progress_update
    executing --> completed_result : success
    executing --> error_result : execution_error
    executing --> timeout_result : execution_timeout
    executing --> cancelled_result : cancelled

    denied --> [*]
    completed_result --> [*]
    error_result --> [*]
    timeout_result --> [*]
    cancelled_result --> [*]

    note right of pending_call
        tool.call rune emitted.
        INV-TOOL-TERMINAL tracking begins.
    end note

    note right of awaiting_approval
        tool.approval_requested rune emitted.
        Client must respond with approve/deny.
    end note

    note right of executing
        tool.progress runes emitted (optional).
        Streaming stdout/stderr for long-running tools.
    end note

    note right of completed_result
        tool.result rune emitted (status: success).
        INV-TOOL-TERMINAL satisfied.
    end note
```

### Tool Events (Rune Kinds)

| State | Rune Kind | Payload |
|---|---|---|
| pending_call | `tool.call` | call_id, tool_name, arguments |
| awaiting_approval | `tool.approval_requested` | call_id, policy_reason |
| approved | `tool.approved` | call_id, approver |
| denied | `tool.denied` | call_id, reason |
| executing (progress) | `tool.progress` | call_id, stdout/stderr chunk |
| completed_result | `tool.result` | call_id, status=success, output |
| error_result | `tool.result` | call_id, status=error, error |
| timeout_result | `tool.result` | call_id, status=timeout |
| cancelled_result | `tool.result` | call_id, status=cancelled |

### Invariants Enforced
- **INV-TOOL-TERMINAL:** Every `tool.call` gets exactly one `tool.result`
- **INV-TOOL-CALL-BEFORE-RESULT:** No `tool.result` without prior `tool.call`
- **INV-TOOL-APPROVAL-BEFORE-EXEC:** Execution blocked until approval when required

---

## Session (Conversation) Lifecycle State Machine

Governs the lifecycle of a conversation from creation to archival.

```mermaid
stateDiagram-v2
    [*] --> created

    created --> active : first_message / agent_ready
    active --> active : new_turn / turn_completed
    active --> paused : pause_requested
    active --> suspended : budget_exhausted / error_threshold
    active --> closing : close_requested

    paused --> active : resume_requested
    paused --> closing : close_requested

    suspended --> active : budget_replenished / reset
    suspended --> closing : close_requested

    closing --> closed : cleanup_complete
    closed --> archived : archive_requested
    archived --> [*]

    note right of created
        Conversation ID allocated.
        Root agent spawned.
        Runelog initialized.
    end note

    note right of active
        Turns execute normally.
        Multiple agents may be active.
        Runes appended continuously.
    end note

    note right of paused
        No new turns accepted.
        In-flight turn completes or interrupts.
        Runelog remains writable (system runes).
    end note

    note right of suspended
        Automatic pause due to budget or errors.
        Requires explicit intervention to resume.
    end note

    note right of closing
        All agents terminated.
        Final runes appended.
        Runelog sealed.
    end note

    note right of archived
        Runelog segments moved to cold storage.
        Metadata retained for listing.
    end note
```

### Session Events (Rune Kinds)

| Transition | Rune Kind | Payload |
|---|---|---|
| [*] -> created | `session.created` | conversation_id, config |
| created -> active | `session.activated` | root_agent_id |
| active -> paused | `session.paused` | reason |
| paused -> active | `session.resumed` | |
| active -> suspended | `session.suspended` | reason, budget_info |
| suspended -> active | `session.unsuspended` | |
| * -> closing | `session.closing` | reason |
| closing -> closed | `session.closed` | final_stats |

---

## Agent Lifecycle State Machine

Governs the lifecycle of a single agent within a conversation.

```mermaid
stateDiagram-v2
    [*] --> spawning

    spawning --> idle : init_complete
    spawning --> failed : init_error

    idle --> running_turn : turn_assigned
    idle --> terminated : kill / parent_closed

    running_turn --> idle : turn_completed
    running_turn --> idle : turn_interrupted
    running_turn --> idle : turn_error
    running_turn --> terminated : kill(force)

    idle --> terminated : budget_exhausted
    terminated --> [*]
    failed --> [*]

    note right of spawning
        Agent process started under OTP supervisor.
        Role, model, tools, budget configured.
        agent.spawned rune emitted by parent.
    end note

    note right of idle
        Agent ready to accept work.
        Waiting for task assignment or user input.
    end note

    note right of running_turn
        TurnEngine state machine active.
        See TurnEngine diagram for substates.
    end note

    note right of terminated
        Agent process stopped.
        agent.terminated rune emitted.
        Resources released.
    end note
```

### Agent Events (Rune Kinds)

| Transition | Rune Kind | Payload |
|---|---|---|
| [*] -> spawning | `agent.spawning` | agent_id, role, model, parent_id |
| spawning -> idle | `agent.ready` | agent_id |
| spawning -> failed | `agent.failed` | agent_id, error |
| idle -> running_turn | `turn.started` | (see TurnEngine) |
| running_turn -> idle | `turn.completed` | (see TurnEngine) |
| * -> terminated | `agent.terminated` | agent_id, reason, stats |

### Invariants Enforced
- **INV-AGENT-SUPERVISED:** OTP supervision, crash containment
- **INV-AGENT-BUDGET:** Budget tracking and enforcement
- **INV-TURN-SEQUENTIAL:** At most one turn active per agent

---

## Autonomy Loop State Machine

Governs the goal-directed planning and execution cycle (Phase 4).

```mermaid
stateDiagram-v2
    [*] --> goal_received

    goal_received --> planning : decompose_goal
    planning --> executing : plan_approved / auto_start
    planning --> goal_received : plan_rejected(revise)
    planning --> stopped : user_cancel

    executing --> reviewing : all_tasks_terminal
    executing --> executing : task_completed(more_pending)
    executing --> blocked : all_runnable_blocked
    executing --> stopped : budget_exhausted / user_cancel

    reviewing --> executing : critique_found_issues(retry)
    reviewing --> goal_met : critique_passed
    reviewing --> planning : needs_replan

    blocked --> executing : dependency_resolved
    blocked --> stopped : unresolvable / user_cancel

    goal_met --> [*]
    stopped --> [*]

    note right of planning
        Orchestrator decomposes goal into tasks.
        plan.created / plan.updated runes emitted.
        Tasks have dependencies, priorities, owners.
    end note

    note right of executing
        Scheduler assigns tasks to available agents.
        task.assigned, task.started, task.completed runes.
        Agents run turns autonomously.
    end note

    note right of reviewing
        Critic agent examines results.
        Structured critique as runes (internal visibility).
        May trigger follow-up tasks or replan.
    end note
```

### Autonomy Events (Rune Kinds)

| State | Rune Kind | Payload |
|---|---|---|
| goal_received | `plan.goal_received` | goal_description |
| planning | `plan.created` | plan_id, tasks |
| planning | `plan.updated` | plan_id, changes |
| executing | `plan.task_assigned` | task_id, agent_id |
| executing | `plan.task_started` | task_id |
| executing | `plan.task_completed` | task_id, result, evidence |
| reviewing | `plan.critique` | plan_id, findings |
| goal_met | `plan.goal_met` | plan_id, summary |
| stopped | `plan.stopped` | reason |
