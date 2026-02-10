/**
 * Core types for the ECHS 2.0 SDK.
 */

// ---------------------------------------------------------------------------
// Client config
// ---------------------------------------------------------------------------

export interface EchsClientOptions {
  /** Base URL of the ECHS server (e.g. "http://localhost:4000") */
  baseUrl: string;
  /** Bearer token for authentication */
  token?: string;
  /** Preferred transport: "ws" | "sse" | "auto" (default: "auto") */
  transport?: "ws" | "sse" | "auto";
  /** Connection timeout in ms (default: 10_000) */
  connectTimeoutMs?: number;
  /** Request timeout in ms (default: 30_000) */
  requestTimeoutMs?: number;
}

// ---------------------------------------------------------------------------
// Rune (the fundamental event type)
// ---------------------------------------------------------------------------

export interface Rune {
  event_id: number;
  rune_id: string;
  conversation_id: string;
  turn_id?: string;
  agent_id?: string;
  kind: RuneKind;
  visibility: "public" | "internal" | "secret";
  ts_ms: number;
  payload: Record<string, unknown>;
  tags: string[];
  schema_version: number;
}

export type RuneKind =
  // Turn events
  | "turn.started"
  | "turn.assistant_delta"
  | "turn.assistant_final"
  | "turn.tool_calls_received"
  | "turn.tools_finished"
  | "turn.completed"
  | "turn.interrupted"
  | "turn.error"
  // Tool events
  | "tool.call"
  | "tool.approval_requested"
  | "tool.approved"
  | "tool.denied"
  | "tool.progress"
  | "tool.result"
  // Agent events
  | "agent.spawning"
  | "agent.ready"
  | "agent.failed"
  | "agent.terminated"
  | "agent.message"
  // Plan events
  | "plan.goal_received"
  | "plan.created"
  | "plan.updated"
  | "plan.task_assigned"
  | "plan.task_updated"
  | "plan.critique"
  | "plan.goal_met"
  | "plan.stopped"
  // Memory events
  | "memory.candidate"
  | "memory.committed"
  // Config events
  | "config.updated"
  | "config.tool_registered"
  | "config.tool_removed"
  // Session events
  | "session.created"
  | "session.activated"
  | "session.paused"
  | "session.resumed"
  | "session.suspended"
  | "session.closed"
  // Checkpoint events
  | "checkpoint.created"
  | "checkpoint.restored"
  // System events
  | "system.invariant_violation"
  | "system.error"
  // Catch-all for future kinds
  | (string & {});

// ---------------------------------------------------------------------------
// Domain entities
// ---------------------------------------------------------------------------

export interface Conversation {
  conversation_id: string;
  active_thread_id?: string;
  created_at: string;
  last_activity_at: string;
  model?: string;
  reasoning?: string;
  cwd?: string;
  instructions?: string;
  coordination_mode?: string;
  tools: string[];
}

export interface ConversationMessage {
  content: string | ContentItem[];
  mode?: "queue" | "steer";
  message_id?: string;
  configure?: Record<string, unknown>;
}

export interface ContentItem {
  type: "input_text" | "input_image";
  text?: string;
  image_url?: string;
}

export interface ToolSpec {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  type?: string;
  side_effects?: boolean;
  idempotent?: boolean;
  streaming?: boolean;
  requires_approval?: "inherit" | "always" | "never";
  timeout?: number;
  max_output_bytes?: number;
  provenance?: "built_in" | "remote" | "mcp" | "custom";
  enabled?: boolean;
}

export interface ToolApproval {
  call_id: string;
  decision: "approved" | "denied";
  reason?: string;
}

export interface Checkpoint {
  checkpoint_id: string;
  workspace_root: string;
  event_id?: number;
  linked_call_id?: string;
  trigger: "manual" | "auto_pre_tool" | "policy";
  created_at_ms: number;
  total_bytes: number;
}

export interface MemoryEntry {
  memory_id: string;
  type: "episodic" | "semantic" | "procedural" | "decision";
  content: string;
  tags: string[];
  confidence: number;
  privacy: "public" | "internal" | "secret";
  source_rune_ids: string[];
  expires_at_ms?: number;
}

export interface PlanTask {
  id: string;
  title: string;
  description: string;
  status: "pending" | "assigned" | "running" | "completed" | "failed" | "blocked" | "cancelled";
  priority: "critical" | "high" | "medium" | "low";
  deps: string[];
  owner?: string;
  success_criteria?: string;
}

export interface Agent {
  agent_id: string;
  role: string;
  model: string;
  status: "spawning" | "idle" | "running" | "terminated";
  parent_id?: string;
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

export interface Subscription {
  /** Async iterator of runes */
  [Symbol.asyncIterator](): AsyncIterator<Rune>;
  /** Unsubscribe and close the connection */
  close(): void;
  /** Resume from a specific event_id */
  resumeFrom(eventId: number): void;
}

export type EventStream = AsyncIterable<Rune>;

// ---------------------------------------------------------------------------
// WebSocket protocol messages
// ---------------------------------------------------------------------------

export interface WsClientMessage {
  type: "subscribe" | "unsubscribe" | "post_message" | "approve" | "interrupt";
  request_id: string;
  conversation_id?: string;
  idempotency_key?: string;
  payload?: Record<string, unknown>;
}

export interface WsServerAck {
  type: "ack";
  request_id: string;
  status: "ok" | "error";
  error?: string;
}

export interface WsServerEvent {
  type: "event";
  conversation_id: string;
  rune: Rune;
}

export interface WsServerGap {
  type: "gap";
  conversation_id: string;
  earliest_available: number;
}

export type WsServerMessage = WsServerAck | WsServerEvent | WsServerGap;
