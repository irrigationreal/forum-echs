/**
 * ECHS 2.0 TypeScript SDK
 *
 * WS-first client with REST fallback for the ECHS agent platform.
 *
 * @example
 * ```ts
 * import { EchsClient } from "@echs/sdk";
 *
 * const client = new EchsClient({ baseUrl: "http://localhost:4000", token: "..." });
 * const conv = await client.createConversation({ model: "gpt-5.3-codex" });
 * const sub = client.subscribe(conv.conversationId);
 * for await (const rune of sub) {
 *   console.log(rune.kind, rune.payload);
 * }
 * ```
 */

export { EchsClient } from "./client.js";
export { WebSocketTransport } from "./ws.js";
export { SSETransport } from "./sse.js";
export type {
  EchsClientOptions,
  Conversation,
  ConversationMessage,
  Rune,
  RuneKind,
  ToolSpec,
  ToolApproval,
  Checkpoint,
  MemoryEntry,
  PlanTask,
  Agent,
  Subscription,
  EventStream,
} from "./types.js";
