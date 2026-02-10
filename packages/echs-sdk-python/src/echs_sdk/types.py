"""Core data types for the ECHS 2.0 Python SDK."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal


# ---------------------------------------------------------------------------
# RuneKind — string union for rune event types
# ---------------------------------------------------------------------------

RuneKind = str  # Open-ended to support future kinds; see canonical list below.

# Canonical rune kinds:
# turn.started, turn.assistant_delta, turn.assistant_final,
# turn.tool_calls_received, turn.tools_finished, turn.completed,
# turn.interrupted, turn.error,
# tool.call, tool.approval_requested, tool.approved, tool.denied,
# tool.progress, tool.result,
# agent.spawning, agent.ready, agent.failed, agent.terminated, agent.message,
# plan.goal_received, plan.created, plan.updated, plan.task_assigned,
# plan.task_updated, plan.critique, plan.goal_met, plan.stopped,
# memory.candidate, memory.committed,
# config.updated, config.tool_registered, config.tool_removed,
# session.created, session.activated, session.paused, session.resumed,
# session.suspended, session.closed,
# checkpoint.created, checkpoint.restored,
# system.invariant_violation, system.error


# ---------------------------------------------------------------------------
# Rune
# ---------------------------------------------------------------------------


@dataclass
class Rune:
    """Immutable typed event record — the fundamental unit of the ECHS runelog."""

    event_id: int
    rune_id: str
    conversation_id: str
    kind: RuneKind
    visibility: Literal["public", "internal", "secret"]
    ts_ms: int
    payload: dict[str, Any] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)
    schema_version: int = 1
    turn_id: str | None = None
    agent_id: str | None = None


# ---------------------------------------------------------------------------
# Domain entities
# ---------------------------------------------------------------------------


@dataclass
class Conversation:
    conversation_id: str
    created_at: str
    last_activity_at: str
    tools: list[str] = field(default_factory=list)
    active_thread_id: str | None = None
    model: str | None = None
    reasoning: str | None = None
    cwd: str | None = None
    instructions: str | None = None
    coordination_mode: str | None = None


@dataclass
class ConversationMessage:
    content: str | list[dict[str, Any]]
    mode: Literal["queue", "steer"] | None = None
    message_id: str | None = None
    configure: dict[str, Any] | None = None


@dataclass
class ToolSpec:
    name: str
    description: str
    parameters: dict[str, Any] = field(default_factory=dict)
    type: str | None = None
    side_effects: bool | None = None
    idempotent: bool | None = None
    streaming: bool | None = None
    requires_approval: Literal["inherit", "always", "never"] | None = None
    timeout: int | None = None
    max_output_bytes: int | None = None
    provenance: Literal["built_in", "remote", "mcp", "custom"] | None = None
    enabled: bool | None = None


@dataclass
class ToolApproval:
    call_id: str
    decision: Literal["approved", "denied"]
    reason: str | None = None


@dataclass
class Checkpoint:
    checkpoint_id: str
    workspace_root: str
    trigger: Literal["manual", "auto_pre_tool", "policy"]
    created_at_ms: int
    total_bytes: int
    event_id: int | None = None
    linked_call_id: str | None = None


@dataclass
class MemoryEntry:
    memory_id: str
    type: Literal["episodic", "semantic", "procedural", "decision"]
    content: str
    tags: list[str] = field(default_factory=list)
    confidence: float = 0.0
    privacy: Literal["public", "internal", "secret"] = "public"
    source_rune_ids: list[str] = field(default_factory=list)
    expires_at_ms: int | None = None


@dataclass
class PlanTask:
    id: str
    title: str
    description: str
    status: Literal["pending", "assigned", "running", "completed", "failed", "blocked", "cancelled"]
    priority: Literal["critical", "high", "medium", "low"]
    deps: list[str] = field(default_factory=list)
    owner: str | None = None
    success_criteria: str | None = None


@dataclass
class Agent:
    agent_id: str
    role: str
    model: str
    status: Literal["spawning", "idle", "running", "terminated"]
    parent_id: str | None = None
