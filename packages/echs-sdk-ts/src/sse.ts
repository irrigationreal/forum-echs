/**
 * SSE (Server-Sent Events) transport for ECHS 2.0 event streaming.
 *
 * Implements Last-Event-ID resume and gap detection.
 */

import type { Rune, Subscription } from "./types.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface SSESubscribeOptions {
  baseUrl: string;
  token?: string;
  conversationId: string;
  sinceEventId?: number;
}

// ---------------------------------------------------------------------------
// SSETransport
// ---------------------------------------------------------------------------

export class SSETransport {
  /**
   * Create a subscription to rune events over SSE.
   *
   * Returns a `Subscription` which is an async iterable of `Rune` objects
   * with `close()` and `resumeFrom()` methods.
   */
  static subscribe(opts: SSESubscribeOptions): Subscription {
    return new SSESubscription(opts);
  }
}

// ---------------------------------------------------------------------------
// SSESubscription
// ---------------------------------------------------------------------------

class SSESubscription implements Subscription {
  private controller: AbortController | null = null;
  private readonly opts: SSESubscribeOptions;
  private readonly runeQueue: Rune[] = [];
  private waiter: ((value: IteratorResult<Rune>) => void) | null = null;
  private closed = false;
  private error: Error | null = null;
  private lastEventId: number | undefined;

  constructor(opts: SSESubscribeOptions) {
    this.opts = opts;
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

    this.controller?.abort();
    this.controller = null;

    if (this.waiter) {
      this.waiter({ done: true, value: undefined });
      this.waiter = null;
    }
  }

  resumeFrom(eventId: number): void {
    this.lastEventId = eventId;
    // Reconnect with the new Last-Event-ID
    this.controller?.abort();
    if (!this.closed) {
      this.connect();
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

  private async connect(): Promise<void> {
    this.controller = new AbortController();

    const url = this.buildUrl();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
    };

    if (this.opts.token) {
      headers["Authorization"] = `Bearer ${this.opts.token}`;
    }

    if (this.lastEventId !== undefined) {
      headers["Last-Event-ID"] = String(this.lastEventId);
    }

    try {
      const res = await fetch(url, {
        headers,
        signal: this.controller.signal,
      });

      if (!res.ok) {
        this.error = new Error(`SSE connect failed: HTTP ${res.status}`);
        if (this.waiter) {
          this.waiter({ done: true, value: undefined });
          this.waiter = null;
        }
        return;
      }

      if (!res.body) {
        this.error = new Error("SSE response has no body");
        if (this.waiter) {
          this.waiter({ done: true, value: undefined });
          this.waiter = null;
        }
        return;
      }

      await this.consumeStream(res.body);
    } catch (err: unknown) {
      if (this.closed) return;
      if (err instanceof DOMException && err.name === "AbortError") return;

      // Auto-reconnect on network errors
      setTimeout(() => {
        if (!this.closed) {
          this.connect();
        }
      }, 1000);
    }
  }

  private async consumeStream(body: ReadableStream<Uint8Array>): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const events = this.parseSSEBuffer(buffer);
        buffer = events.remaining;

        for (const event of events.parsed) {
          this.handleSSEEvent(event);
        }
      }
    } catch (err: unknown) {
      if (this.closed) return;
      if (err instanceof DOMException && err.name === "AbortError") return;
      throw err;
    } finally {
      reader.releaseLock();
    }

    // Stream ended — reconnect unless closed
    if (!this.closed) {
      setTimeout(() => {
        if (!this.closed) {
          this.connect();
        }
      }, 1000);
    }
  }

  private handleSSEEvent(event: SSEEvent): void {
    if (event.type === "gap") {
      try {
        const data = JSON.parse(event.data);
        this.pushRune({
          event_id: data.earliest_available ?? 0,
          rune_id: `gap_${Date.now()}`,
          conversation_id: this.opts.conversationId,
          kind: "system.gap",
          visibility: "internal",
          ts_ms: Date.now(),
          payload: data,
          tags: ["gap"],
          schema_version: 1,
        });
      } catch {
        // Ignore malformed gap events
      }
      return;
    }

    // Default event type is "rune" or unspecified
    try {
      const rune = JSON.parse(event.data) as Rune;
      this.pushRune(rune);
    } catch {
      // Ignore malformed events
    }
  }

  private buildUrl(): string {
    const base = this.opts.baseUrl.replace(/\/+$/, "");
    let url = `${base}/v2/conversations/${this.opts.conversationId}/events`;

    if (this.lastEventId !== undefined) {
      url += `?since_event_id=${this.lastEventId}`;
    }

    return url;
  }

  private parseSSEBuffer(buffer: string): {
    parsed: SSEEvent[];
    remaining: string;
  } {
    const parsed: SSEEvent[] = [];
    const lines = buffer.split("\n");

    let currentEvent: Partial<SSEEvent> = {};
    let dataLines: string[] = [];
    let i = 0;

    while (i < lines.length) {
      const line = lines[i];

      // Check if this is the last line and might be incomplete
      if (i === lines.length - 1 && !buffer.endsWith("\n")) {
        // Incomplete line — return as remaining
        return { parsed, remaining: lines.slice(i).join("\n") };
      }

      if (line === "") {
        // Empty line = event boundary
        if (dataLines.length > 0) {
          parsed.push({
            type: currentEvent.type ?? "message",
            data: dataLines.join("\n"),
            id: currentEvent.id,
          });
        }
        currentEvent = {};
        dataLines = [];
      } else if (line.startsWith("data:")) {
        dataLines.push(line.slice(5).trimStart());
      } else if (line.startsWith("event:")) {
        currentEvent.type = line.slice(6).trimStart();
      } else if (line.startsWith("id:")) {
        currentEvent.id = line.slice(3).trimStart();
      } else if (line.startsWith("retry:")) {
        // Ignore retry directives for now
      }
      // Ignore comment lines starting with ":"

      i++;
    }

    // Whatever is left after the last event boundary is remaining
    const remaining = dataLines.length > 0 || currentEvent.type
      ? lines.slice(i).join("\n")
      : "";

    return { parsed, remaining };
  }
}

// ---------------------------------------------------------------------------
// SSE types
// ---------------------------------------------------------------------------

interface SSEEvent {
  type: string;
  data: string;
  id?: string;
}
