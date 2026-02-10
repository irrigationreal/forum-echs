/**
 * WebSocket transport for ECHS 2.0 event streaming.
 *
 * Implements the multiplexed WS protocol with subscribe/resume/post_message,
 * request_id ACKs, and idempotency keys.
 */

import type {
  Rune,
  Subscription,
  WsClientMessage,
  WsServerMessage,
  WsServerEvent,
  WsServerGap,
} from "./types.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface SubscribeOptions {
  baseUrl: string;
  token?: string;
  conversationId: string;
  sinceEventId?: number;
  connectTimeoutMs?: number;
}

interface PendingRequest {
  resolve: (value: void) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

// ---------------------------------------------------------------------------
// WebSocketTransport
// ---------------------------------------------------------------------------

export class WebSocketTransport {
  /**
   * Create a subscription to rune events over WebSocket.
   *
   * Returns a `Subscription` which is an async iterable of `Rune` objects
   * with `close()` and `resumeFrom()` methods.
   */
  static subscribe(opts: SubscribeOptions): Subscription {
    return new WsSubscription(opts);
  }
}

// ---------------------------------------------------------------------------
// WsSubscription
// ---------------------------------------------------------------------------

class WsSubscription implements Subscription {
  private ws: WebSocket | null = null;
  private readonly opts: Required<SubscribeOptions>;
  private readonly runeQueue: Rune[] = [];
  private readonly pendingRequests = new Map<string, PendingRequest>();
  private waiter: ((value: IteratorResult<Rune>) => void) | null = null;
  private closed = false;
  private error: Error | null = null;
  private lastEventId: number | undefined;
  private requestCounter = 0;

  constructor(opts: SubscribeOptions) {
    this.opts = {
      baseUrl: opts.baseUrl,
      token: opts.token ?? "",
      conversationId: opts.conversationId,
      sinceEventId: opts.sinceEventId,
      connectTimeoutMs: opts.connectTimeoutMs ?? 10_000,
    };
    this.lastEventId = opts.sinceEventId;
    this.connect();
  }

  // --- Subscription interface ---

  [Symbol.asyncIterator](): AsyncIterator<Rune> {
    return {
      next: () => this.next(),
      return: async () => {
        this.close();
        return { done: true, value: undefined };
      },
    };
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;

    // Reject pending requests
    for (const [, pending] of this.pendingRequests) {
      clearTimeout(pending.timer);
      pending.reject(new Error("Subscription closed"));
    }
    this.pendingRequests.clear();

    // Resolve any waiting consumer
    if (this.waiter) {
      this.waiter({ done: true, value: undefined });
      this.waiter = null;
    }

    if (this.ws) {
      this.ws.close(1000, "client close");
      this.ws = null;
    }
  }

  resumeFrom(eventId: number): void {
    this.lastEventId = eventId;

    // If connected, send a new subscribe with since_event_id
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.sendSubscribe();
    }
  }

  // --- Internal ---

  private next(): Promise<IteratorResult<Rune>> {
    if (this.error) {
      return Promise.reject(this.error);
    }

    if (this.runeQueue.length > 0) {
      return Promise.resolve({ done: false, value: this.runeQueue.shift()! });
    }

    if (this.closed) {
      return Promise.resolve({ done: true, value: undefined });
    }

    return new Promise<IteratorResult<Rune>>((resolve) => {
      this.waiter = resolve;
    });
  }

  private pushRune(rune: Rune): void {
    if (this.closed) return;

    this.lastEventId = rune.event_id;

    if (this.waiter) {
      const w = this.waiter;
      this.waiter = null;
      w({ done: false, value: rune });
    } else {
      this.runeQueue.push(rune);
    }
  }

  private connect(): void {
    const wsUrl = this.opts.baseUrl
      .replace(/^http/, "ws")
      .replace(/\/+$/, "");

    const url = this.opts.token
      ? `${wsUrl}/v2/ws?token=${encodeURIComponent(this.opts.token)}`
      : `${wsUrl}/v2/ws`;

    this.ws = new WebSocket(url);

    const connectTimer = setTimeout(() => {
      if (this.ws?.readyState !== WebSocket.OPEN) {
        this.ws?.close();
        this.error = new Error(`WebSocket connect timeout (${this.opts.connectTimeoutMs}ms)`);
        if (this.waiter) {
          this.waiter({ done: true, value: undefined });
          this.waiter = null;
        }
      }
    }, this.opts.connectTimeoutMs);

    this.ws.onopen = () => {
      clearTimeout(connectTimer);
      this.sendSubscribe();
    };

    this.ws.onmessage = (event) => {
      this.handleMessage(event.data as string);
    };

    this.ws.onerror = () => {
      // onclose will fire after onerror
    };

    this.ws.onclose = (event) => {
      clearTimeout(connectTimer);

      if (!this.closed) {
        // Unexpected close — attempt reconnect after a delay
        setTimeout(() => {
          if (!this.closed) {
            this.connect();
          }
        }, 1000);
      }
    };
  }

  private sendSubscribe(): void {
    const msg: WsClientMessage = {
      type: "subscribe",
      request_id: this.nextRequestId(),
      conversation_id: this.opts.conversationId,
    };

    if (this.lastEventId !== undefined) {
      msg.payload = { since_event_id: this.lastEventId };
    }

    this.send(msg);
  }

  private handleMessage(raw: string): void {
    let msg: WsServerMessage;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    switch (msg.type) {
      case "ack": {
        const pending = this.pendingRequests.get(msg.request_id);
        if (pending) {
          this.pendingRequests.delete(msg.request_id);
          clearTimeout(pending.timer);
          if (msg.status === "ok") {
            pending.resolve();
          } else {
            pending.reject(new Error(msg.error ?? "Unknown ACK error"));
          }
        }
        break;
      }

      case "event": {
        const evt = msg as WsServerEvent;
        if (evt.conversation_id === this.opts.conversationId) {
          this.pushRune(evt.rune);
        }
        break;
      }

      case "gap": {
        const gap = msg as WsServerGap;
        // Gap signal means the server cannot backfill from our last event.
        // We emit a synthetic rune so consumers can detect the discontinuity.
        this.pushRune({
          event_id: gap.earliest_available,
          rune_id: `gap_${Date.now()}`,
          conversation_id: gap.conversation_id,
          kind: "system.gap",
          visibility: "internal",
          ts_ms: Date.now(),
          payload: { earliest_available: gap.earliest_available },
          tags: ["gap"],
          schema_version: 1,
        });
        break;
      }
    }
  }

  private send(msg: WsClientMessage): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify(msg));
  }

  private nextRequestId(): string {
    return `req_${++this.requestCounter}_${Date.now()}`;
  }
}
