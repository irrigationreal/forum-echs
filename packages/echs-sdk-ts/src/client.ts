/**
 * EchsClient — main entry point for the ECHS 2.0 TypeScript SDK.
 *
 * Provides REST methods for all v2 API endpoints and transport-agnostic
 * streaming via WebSocket or SSE.
 */

import type {
  EchsClientOptions,
  Conversation,
  ConversationMessage,
  Rune,
  ToolSpec,
  ToolApproval,
  Checkpoint,
  MemoryEntry,
  PlanTask,
  Agent,
  Subscription,
} from "./types.js";
import { WebSocketTransport } from "./ws.js";
import { SSETransport } from "./sse.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class EchsApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: unknown,
  ) {
    super(`ECHS API error ${status}: ${JSON.stringify(body)}`);
    this.name = "EchsApiError";
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export class EchsClient {
  private readonly baseUrl: string;
  private readonly token?: string;
  private readonly transport: "ws" | "sse" | "auto";
  private readonly connectTimeoutMs: number;
  private readonly requestTimeoutMs: number;

  constructor(opts: EchsClientOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, "");
    this.token = opts.token;
    this.transport = opts.transport ?? "auto";
    this.connectTimeoutMs = opts.connectTimeoutMs ?? 10_000;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 30_000;
  }

  // -----------------------------------------------------------------------
  // Conversations
  // -----------------------------------------------------------------------

  async createConversation(
    params: {
      model?: string;
      reasoning?: string;
      cwd?: string;
      instructions?: string;
      tools?: string[];
      coordination_mode?: string;
    } = {},
  ): Promise<Conversation> {
    return this.post<Conversation>("/v2/conversations", params);
  }

  async listConversations(): Promise<Conversation[]> {
    const res = await this.get<{ conversations: Conversation[] }>("/v2/conversations");
    return res.conversations;
  }

  async getConversation(conversationId: string): Promise<Conversation> {
    return this.get<Conversation>(`/v2/conversations/${conversationId}`);
  }

  async updateConversation(
    conversationId: string,
    params: Partial<Pick<Conversation, "model" | "reasoning" | "instructions" | "tools">>,
  ): Promise<Conversation> {
    return this.patch<Conversation>(`/v2/conversations/${conversationId}`, params);
  }

  async deleteConversation(conversationId: string): Promise<void> {
    await this.del(`/v2/conversations/${conversationId}`);
  }

  // -----------------------------------------------------------------------
  // Messages
  // -----------------------------------------------------------------------

  async postMessage(
    conversationId: string,
    message: ConversationMessage,
  ): Promise<{ message_id: string }> {
    return this.post(`/v2/conversations/${conversationId}/messages`, message);
  }

  async listMessages(
    conversationId: string,
    params?: { limit?: number; before?: string },
  ): Promise<{ messages: Array<{ message_id: string; role: string; content: unknown }> }> {
    const qs = new URLSearchParams();
    if (params?.limit) qs.set("limit", String(params.limit));
    if (params?.before) qs.set("before", params.before);
    const query = qs.toString();
    const path = `/v2/conversations/${conversationId}/messages` + (query ? `?${query}` : "");
    return this.get(path);
  }

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  async interrupt(conversationId: string): Promise<void> {
    await this.post(`/v2/conversations/${conversationId}/interrupt`, {});
  }

  async pause(conversationId: string): Promise<void> {
    await this.post(`/v2/conversations/${conversationId}/pause`, {});
  }

  async resume(conversationId: string): Promise<void> {
    await this.post(`/v2/conversations/${conversationId}/resume`, {});
  }

  // -----------------------------------------------------------------------
  // Tools
  // -----------------------------------------------------------------------

  async listTools(conversationId: string): Promise<ToolSpec[]> {
    const res = await this.get<{ tools: ToolSpec[] }>(
      `/v2/conversations/${conversationId}/tools`,
    );
    return res.tools;
  }

  async registerTool(conversationId: string, tool: ToolSpec): Promise<ToolSpec> {
    return this.post(`/v2/conversations/${conversationId}/tools`, tool);
  }

  async unregisterTool(conversationId: string, toolName: string): Promise<void> {
    await this.del(`/v2/conversations/${conversationId}/tools/${encodeURIComponent(toolName)}`);
  }

  async approveTool(conversationId: string, approval: ToolApproval): Promise<void> {
    await this.post(
      `/v2/conversations/${conversationId}/tools/${encodeURIComponent(approval.call_id)}/approve`,
      approval,
    );
  }

  // -----------------------------------------------------------------------
  // Checkpoints
  // -----------------------------------------------------------------------

  async listCheckpoints(conversationId: string): Promise<Checkpoint[]> {
    const res = await this.get<{ checkpoints: Checkpoint[] }>(
      `/v2/conversations/${conversationId}/checkpoints`,
    );
    return res.checkpoints;
  }

  async createCheckpoint(
    conversationId: string,
    params?: { trigger?: Checkpoint["trigger"] },
  ): Promise<Checkpoint> {
    return this.post(`/v2/conversations/${conversationId}/checkpoints`, params ?? {});
  }

  async restoreCheckpoint(
    conversationId: string,
    checkpointId: string,
    opts?: { dry_run?: boolean },
  ): Promise<{ restored: boolean; diff?: unknown }> {
    return this.post(
      `/v2/conversations/${conversationId}/checkpoints/${checkpointId}/restore`,
      opts ?? {},
    );
  }

  // -----------------------------------------------------------------------
  // Memory
  // -----------------------------------------------------------------------

  async listMemories(
    conversationId: string,
    params?: { type?: MemoryEntry["type"]; min_confidence?: number },
  ): Promise<MemoryEntry[]> {
    const qs = new URLSearchParams();
    if (params?.type) qs.set("type", params.type);
    if (params?.min_confidence != null) qs.set("min_confidence", String(params.min_confidence));
    const query = qs.toString();
    const path = `/v2/conversations/${conversationId}/memories` + (query ? `?${query}` : "");
    const res = await this.get<{ memories: MemoryEntry[] }>(path);
    return res.memories;
  }

  async createMemory(
    conversationId: string,
    entry: Omit<MemoryEntry, "memory_id" | "source_rune_ids">,
  ): Promise<MemoryEntry> {
    return this.post(`/v2/conversations/${conversationId}/memories`, entry);
  }

  async getMemory(conversationId: string, memoryId: string): Promise<MemoryEntry> {
    return this.get(`/v2/conversations/${conversationId}/memories/${memoryId}`);
  }

  async deleteMemory(conversationId: string, memoryId: string): Promise<void> {
    await this.del(`/v2/conversations/${conversationId}/memories/${memoryId}`);
  }

  async searchMemories(
    conversationId: string,
    params: { query: string; type?: MemoryEntry["type"]; limit?: number },
  ): Promise<MemoryEntry[]> {
    const res = await this.post<{ results: MemoryEntry[] }>(
      `/v2/conversations/${conversationId}/memories/search`,
      params,
    );
    return res.results;
  }

  // -----------------------------------------------------------------------
  // Plan
  // -----------------------------------------------------------------------

  async getPlan(
    conversationId: string,
  ): Promise<{ tasks: PlanTask[]; status_counts: Record<string, number> }> {
    return this.get(`/v2/conversations/${conversationId}/plan`);
  }

  async updateTask(
    conversationId: string,
    taskId: string,
    updates: Partial<Pick<PlanTask, "status" | "priority" | "owner" | "description">>,
  ): Promise<PlanTask> {
    return this.patch(`/v2/conversations/${conversationId}/plan/tasks/${taskId}`, updates);
  }

  // -----------------------------------------------------------------------
  // Agents
  // -----------------------------------------------------------------------

  async listAgents(conversationId: string): Promise<Agent[]> {
    const res = await this.get<{ agents: Agent[] }>(
      `/v2/conversations/${conversationId}/agents`,
    );
    return res.agents;
  }

  async spawnAgent(
    conversationId: string,
    params: { role: string; model: string; budget?: { max_tokens?: number; max_tool_calls?: number } },
  ): Promise<Agent> {
    return this.post(`/v2/conversations/${conversationId}/agents`, params);
  }

  async getAgent(conversationId: string, agentId: string): Promise<Agent> {
    return this.get(`/v2/conversations/${conversationId}/agents/${agentId}`);
  }

  async terminateAgent(
    conversationId: string,
    agentId: string,
    reason?: string,
  ): Promise<void> {
    await this.post(`/v2/conversations/${conversationId}/agents/${agentId}/terminate`, {
      reason,
    });
  }

  // -----------------------------------------------------------------------
  // MCP
  // -----------------------------------------------------------------------

  async listMcpServers(): Promise<Array<{ name: string; status: string }>> {
    const res = await this.get<{ servers: Array<{ name: string; status: string }> }>(
      "/v2/mcp/servers",
    );
    return res.servers;
  }

  async addMcpServer(params: {
    name: string;
    command: string;
    args?: string[];
    env?: Record<string, string>;
  }): Promise<{ name: string; status: string }> {
    return this.post("/v2/mcp/servers", params);
  }

  // -----------------------------------------------------------------------
  // Streaming
  // -----------------------------------------------------------------------

  /**
   * Subscribe to rune events for a conversation.
   *
   * Automatically selects the best available transport (WebSocket preferred,
   * SSE fallback) unless overridden in client options.
   */
  subscribe(
    conversationId: string,
    opts?: { sinceEventId?: number },
  ): Subscription {
    const transport = this.resolveTransport();

    if (transport === "ws") {
      return WebSocketTransport.subscribe({
        baseUrl: this.baseUrl,
        token: this.token,
        conversationId,
        sinceEventId: opts?.sinceEventId,
        connectTimeoutMs: this.connectTimeoutMs,
      });
    }

    return SSETransport.subscribe({
      baseUrl: this.baseUrl,
      token: this.token,
      conversationId,
      sinceEventId: opts?.sinceEventId,
    });
  }

  // -----------------------------------------------------------------------
  // HTTP primitives
  // -----------------------------------------------------------------------

  private async get<T>(path: string): Promise<T> {
    return this.request<T>("GET", path);
  }

  private async post<T>(path: string, body?: unknown): Promise<T> {
    return this.request<T>("POST", path, body);
  }

  private async patch<T>(path: string, body?: unknown): Promise<T> {
    return this.request<T>("PATCH", path, body);
  }

  private async del(path: string): Promise<void> {
    await this.request<void>("DELETE", path);
  }

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const url = `${this.baseUrl}${path}`;
    const headers: Record<string, string> = {
      Accept: "application/json",
    };

    if (this.token) {
      headers["Authorization"] = `Bearer ${this.token}`;
    }

    const init: RequestInit = {
      method,
      headers,
      signal: AbortSignal.timeout(this.requestTimeoutMs),
    };

    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }

    const res = await fetch(url, init);

    if (!res.ok) {
      const errBody = await res.text().catch(() => "");
      let parsed: unknown;
      try {
        parsed = JSON.parse(errBody);
      } catch {
        parsed = errBody;
      }
      throw new EchsApiError(res.status, parsed);
    }

    if (res.status === 204 || method === "DELETE") {
      return undefined as T;
    }

    return (await res.json()) as T;
  }

  private resolveTransport(): "ws" | "sse" {
    if (this.transport === "ws" || this.transport === "sse") {
      return this.transport;
    }

    // "auto" — prefer WS when available (Node.js 20+ or browser with WebSocket)
    if (typeof globalThis.WebSocket !== "undefined") {
      return "ws";
    }

    return "sse";
  }
}

export { EchsApiError };
