/**
 * Tests for EchsClient REST methods.
 *
 * Uses vitest with fetch mocking to validate request shapes and
 * response parsing without a live server.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EchsClient } from "../src/client.js";
import type { Conversation, ToolSpec, MemoryEntry, PlanTask, Agent } from "../src/types.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function mockFetch(status: number, body: unknown) {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  });
}

function client(opts?: { token?: string }) {
  return new EchsClient({
    baseUrl: "http://localhost:4000",
    token: opts?.token ?? "test-token",
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("EchsClient", () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  // --- Conversations ---

  describe("createConversation", () => {
    it("sends POST /v2/conversations with params", async () => {
      const conv: Conversation = {
        conversation_id: "conv_1",
        created_at: "2026-01-01T00:00:00Z",
        last_activity_at: "2026-01-01T00:00:00Z",
        model: "gpt-5.3-codex",
        tools: [],
      };
      globalThis.fetch = mockFetch(200, conv);

      const result = await client().createConversation({ model: "gpt-5.3-codex" });

      expect(result.conversation_id).toBe("conv_1");
      expect(globalThis.fetch).toHaveBeenCalledTimes(1);

      const [url, init] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toBe("http://localhost:4000/v2/conversations");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body)).toEqual({ model: "gpt-5.3-codex" });
      expect(init.headers["Authorization"]).toBe("Bearer test-token");
    });
  });

  describe("listConversations", () => {
    it("sends GET /v2/conversations", async () => {
      globalThis.fetch = mockFetch(200, { conversations: [] });
      const result = await client().listConversations();
      expect(result).toEqual([]);
    });
  });

  describe("getConversation", () => {
    it("sends GET /v2/conversations/:id", async () => {
      const conv: Conversation = {
        conversation_id: "conv_1",
        created_at: "2026-01-01T00:00:00Z",
        last_activity_at: "2026-01-01T00:00:00Z",
        tools: [],
      };
      globalThis.fetch = mockFetch(200, conv);
      const result = await client().getConversation("conv_1");
      expect(result.conversation_id).toBe("conv_1");

      const [url] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toBe("http://localhost:4000/v2/conversations/conv_1");
    });
  });

  describe("deleteConversation", () => {
    it("sends DELETE /v2/conversations/:id", async () => {
      globalThis.fetch = mockFetch(204, undefined);
      await client().deleteConversation("conv_1");

      const [url, init] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toBe("http://localhost:4000/v2/conversations/conv_1");
      expect(init.method).toBe("DELETE");
    });
  });

  // --- Messages ---

  describe("postMessage", () => {
    it("sends POST with message body", async () => {
      globalThis.fetch = mockFetch(200, { message_id: "msg_1" });
      const result = await client().postMessage("conv_1", { content: "Hello" });
      expect(result.message_id).toBe("msg_1");

      const [url, init] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toBe("http://localhost:4000/v2/conversations/conv_1/messages");
      expect(JSON.parse(init.body)).toEqual({ content: "Hello" });
    });
  });

  // --- Lifecycle ---

  describe("interrupt", () => {
    it("sends POST /v2/conversations/:id/interrupt", async () => {
      globalThis.fetch = mockFetch(200, {});
      await client().interrupt("conv_1");

      const [url, init] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toBe("http://localhost:4000/v2/conversations/conv_1/interrupt");
      expect(init.method).toBe("POST");
    });
  });

  // --- Tools ---

  describe("listTools", () => {
    it("returns tool array", async () => {
      const tools: ToolSpec[] = [
        { name: "bash", description: "Run bash", parameters: {} },
      ];
      globalThis.fetch = mockFetch(200, { tools });
      const result = await client().listTools("conv_1");
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe("bash");
    });
  });

  describe("registerTool", () => {
    it("sends POST with tool spec", async () => {
      const tool: ToolSpec = {
        name: "custom_tool",
        description: "A custom tool",
        parameters: { type: "object" },
        side_effects: true,
        requires_approval: "always",
      };
      globalThis.fetch = mockFetch(201, tool);
      const result = await client().registerTool("conv_1", tool);
      expect(result.name).toBe("custom_tool");
    });
  });

  describe("approveTool", () => {
    it("sends approval to correct path", async () => {
      globalThis.fetch = mockFetch(200, {});
      await client().approveTool("conv_1", {
        call_id: "call_42",
        decision: "approved",
        reason: "looks safe",
      });

      const [url] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toBe("http://localhost:4000/v2/conversations/conv_1/tools/call_42/approve");
    });
  });

  // --- Checkpoints ---

  describe("listCheckpoints", () => {
    it("returns checkpoint array", async () => {
      globalThis.fetch = mockFetch(200, { checkpoints: [] });
      const result = await client().listCheckpoints("conv_1");
      expect(result).toEqual([]);
    });
  });

  describe("createCheckpoint", () => {
    it("sends POST with trigger", async () => {
      const cp = {
        checkpoint_id: "chk_1",
        workspace_root: "/tmp/ws",
        trigger: "manual" as const,
        created_at_ms: 1000,
        total_bytes: 4096,
      };
      globalThis.fetch = mockFetch(201, cp);
      const result = await client().createCheckpoint("conv_1", { trigger: "manual" });
      expect(result.checkpoint_id).toBe("chk_1");
    });
  });

  // --- Memory ---

  describe("listMemories", () => {
    it("adds query params for type and min_confidence", async () => {
      globalThis.fetch = mockFetch(200, { memories: [] });
      await client().listMemories("conv_1", { type: "episodic", min_confidence: 0.5 });

      const [url] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(url).toContain("type=episodic");
      expect(url).toContain("min_confidence=0.5");
    });
  });

  describe("searchMemories", () => {
    it("sends POST to search endpoint", async () => {
      const entry: MemoryEntry = {
        memory_id: "mem_1",
        type: "semantic",
        content: "test",
        tags: [],
        confidence: 0.9,
        privacy: "public",
        source_rune_ids: [],
      };
      globalThis.fetch = mockFetch(200, { results: [entry] });
      const result = await client().searchMemories("conv_1", { query: "test" });
      expect(result).toHaveLength(1);
      expect(result[0].memory_id).toBe("mem_1");
    });
  });

  // --- Plan ---

  describe("getPlan", () => {
    it("returns tasks and status counts", async () => {
      const plan = {
        tasks: [],
        status_counts: { pending: 0, completed: 0 },
      };
      globalThis.fetch = mockFetch(200, plan);
      const result = await client().getPlan("conv_1");
      expect(result.tasks).toEqual([]);
    });
  });

  describe("updateTask", () => {
    it("sends PATCH with updates", async () => {
      const task: PlanTask = {
        id: "task_1",
        title: "Test",
        description: "Do test",
        status: "completed",
        priority: "high",
        deps: [],
      };
      globalThis.fetch = mockFetch(200, task);
      const result = await client().updateTask("conv_1", "task_1", { status: "completed" });
      expect(result.status).toBe("completed");
    });
  });

  // --- Agents ---

  describe("listAgents", () => {
    it("returns agent array", async () => {
      globalThis.fetch = mockFetch(200, { agents: [] });
      const result = await client().listAgents("conv_1");
      expect(result).toEqual([]);
    });
  });

  describe("spawnAgent", () => {
    it("sends POST with role and model", async () => {
      const agent: Agent = {
        agent_id: "agent_1",
        role: "worker",
        model: "gpt-5.3-codex",
        status: "spawning",
      };
      globalThis.fetch = mockFetch(201, agent);
      const result = await client().spawnAgent("conv_1", {
        role: "worker",
        model: "gpt-5.3-codex",
      });
      expect(result.agent_id).toBe("agent_1");
    });
  });

  // --- Error handling ---

  describe("error handling", () => {
    it("throws EchsApiError on non-2xx response", async () => {
      globalThis.fetch = mockFetch(404, { error: "not_found" });

      await expect(client().getConversation("missing")).rejects.toThrow("ECHS API error 404");
    });

    it("includes Authorization header when token is set", async () => {
      globalThis.fetch = mockFetch(200, { conversations: [] });
      await client({ token: "my-secret" }).listConversations();

      const [, init] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(init.headers["Authorization"]).toBe("Bearer my-secret");
    });

    it("omits Authorization header when no token", async () => {
      globalThis.fetch = mockFetch(200, { conversations: [] });
      await new EchsClient({ baseUrl: "http://localhost:4000" }).listConversations();

      const [, init] = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
      expect(init.headers["Authorization"]).toBeUndefined();
    });
  });

  // --- MCP ---

  describe("listMcpServers", () => {
    it("returns server list", async () => {
      globalThis.fetch = mockFetch(200, {
        servers: [{ name: "test-mcp", status: "connected" }],
      });
      const result = await client().listMcpServers();
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe("test-mcp");
    });
  });
});
