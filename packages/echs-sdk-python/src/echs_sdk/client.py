"""
ECHS 2.0 Python client — async-first with sync wrapper.

Provides full REST coverage for the v2 API and async streaming
via WebSocket or SSE transports.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import asdict
from typing import Any, AsyncIterator

import httpx

from .types import (
    Agent,
    Checkpoint,
    Conversation,
    ConversationMessage,
    MemoryEntry,
    PlanTask,
    Rune,
    ToolApproval,
    ToolSpec,
)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class EchsApiError(Exception):
    """Raised when the ECHS API returns a non-2xx response."""

    def __init__(self, status: int, body: Any) -> None:
        self.status = status
        self.body = body
        super().__init__(f"ECHS API error {status}: {body}")


# ---------------------------------------------------------------------------
# Async client
# ---------------------------------------------------------------------------


class EchsAsyncClient:
    """Async client for the ECHS 2.0 API."""

    def __init__(
        self,
        base_url: str,
        token: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        headers: dict[str, str] = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self._http = httpx.AsyncClient(
            base_url=self.base_url,
            headers=headers,
            timeout=timeout,
        )

    async def close(self) -> None:
        await self._http.aclose()

    async def __aenter__(self) -> EchsAsyncClient:
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.close()

    # --- Conversations ---

    async def create_conversation(self, **kwargs: Any) -> Conversation:
        data = await self._post("/v2/conversations", json=kwargs)
        return _parse_conversation(data)

    async def list_conversations(self) -> list[Conversation]:
        data = await self._get("/v2/conversations")
        return [_parse_conversation(c) for c in data.get("conversations", [])]

    async def get_conversation(self, conversation_id: str) -> Conversation:
        data = await self._get(f"/v2/conversations/{conversation_id}")
        return _parse_conversation(data)

    async def update_conversation(self, conversation_id: str, **kwargs: Any) -> Conversation:
        data = await self._patch(f"/v2/conversations/{conversation_id}", json=kwargs)
        return _parse_conversation(data)

    async def delete_conversation(self, conversation_id: str) -> None:
        await self._delete(f"/v2/conversations/{conversation_id}")

    # --- Messages ---

    async def post_message(
        self, conversation_id: str, message: ConversationMessage
    ) -> dict[str, Any]:
        return await self._post(
            f"/v2/conversations/{conversation_id}/messages",
            json=_to_dict(message),
        )

    async def list_messages(
        self,
        conversation_id: str,
        limit: int | None = None,
        before: str | None = None,
    ) -> list[dict[str, Any]]:
        params: dict[str, Any] = {}
        if limit is not None:
            params["limit"] = limit
        if before is not None:
            params["before"] = before
        data = await self._get(
            f"/v2/conversations/{conversation_id}/messages", params=params
        )
        return data.get("messages", [])

    # --- Lifecycle ---

    async def interrupt(self, conversation_id: str) -> None:
        await self._post(f"/v2/conversations/{conversation_id}/interrupt", json={})

    async def pause(self, conversation_id: str) -> None:
        await self._post(f"/v2/conversations/{conversation_id}/pause", json={})

    async def resume(self, conversation_id: str) -> None:
        await self._post(f"/v2/conversations/{conversation_id}/resume", json={})

    # --- Tools ---

    async def list_tools(self, conversation_id: str) -> list[ToolSpec]:
        data = await self._get(f"/v2/conversations/{conversation_id}/tools")
        return [_parse_tool(t) for t in data.get("tools", [])]

    async def register_tool(self, conversation_id: str, tool: ToolSpec) -> ToolSpec:
        data = await self._post(
            f"/v2/conversations/{conversation_id}/tools",
            json=_to_dict(tool),
        )
        return _parse_tool(data)

    async def unregister_tool(self, conversation_id: str, tool_name: str) -> None:
        await self._delete(f"/v2/conversations/{conversation_id}/tools/{tool_name}")

    async def approve_tool(self, conversation_id: str, approval: ToolApproval) -> None:
        await self._post(
            f"/v2/conversations/{conversation_id}/tools/{approval.call_id}/approve",
            json=_to_dict(approval),
        )

    # --- Checkpoints ---

    async def list_checkpoints(self, conversation_id: str) -> list[Checkpoint]:
        data = await self._get(f"/v2/conversations/{conversation_id}/checkpoints")
        return [_parse_checkpoint(c) for c in data.get("checkpoints", [])]

    async def create_checkpoint(
        self, conversation_id: str, trigger: str = "manual"
    ) -> Checkpoint:
        data = await self._post(
            f"/v2/conversations/{conversation_id}/checkpoints",
            json={"trigger": trigger},
        )
        return _parse_checkpoint(data)

    async def restore_checkpoint(
        self,
        conversation_id: str,
        checkpoint_id: str,
        dry_run: bool = False,
    ) -> dict[str, Any]:
        return await self._post(
            f"/v2/conversations/{conversation_id}/checkpoints/{checkpoint_id}/restore",
            json={"dry_run": dry_run},
        )

    # --- Memory ---

    async def list_memories(
        self,
        conversation_id: str,
        type: str | None = None,
        min_confidence: float | None = None,
    ) -> list[MemoryEntry]:
        params: dict[str, Any] = {}
        if type is not None:
            params["type"] = type
        if min_confidence is not None:
            params["min_confidence"] = min_confidence
        data = await self._get(
            f"/v2/conversations/{conversation_id}/memories", params=params
        )
        return [_parse_memory(m) for m in data.get("memories", [])]

    async def create_memory(
        self, conversation_id: str, entry: MemoryEntry
    ) -> MemoryEntry:
        data = await self._post(
            f"/v2/conversations/{conversation_id}/memories",
            json=_to_dict(entry),
        )
        return _parse_memory(data)

    async def get_memory(self, conversation_id: str, memory_id: str) -> MemoryEntry:
        data = await self._get(
            f"/v2/conversations/{conversation_id}/memories/{memory_id}"
        )
        return _parse_memory(data)

    async def delete_memory(self, conversation_id: str, memory_id: str) -> None:
        await self._delete(
            f"/v2/conversations/{conversation_id}/memories/{memory_id}"
        )

    async def search_memories(
        self,
        conversation_id: str,
        query: str,
        type: str | None = None,
        limit: int | None = None,
    ) -> list[MemoryEntry]:
        body: dict[str, Any] = {"query": query}
        if type is not None:
            body["type"] = type
        if limit is not None:
            body["limit"] = limit
        data = await self._post(
            f"/v2/conversations/{conversation_id}/memories/search", json=body
        )
        return [_parse_memory(m) for m in data.get("results", [])]

    # --- Plan ---

    async def get_plan(self, conversation_id: str) -> dict[str, Any]:
        return await self._get(f"/v2/conversations/{conversation_id}/plan")

    async def update_task(
        self, conversation_id: str, task_id: str, **kwargs: Any
    ) -> PlanTask:
        data = await self._patch(
            f"/v2/conversations/{conversation_id}/plan/tasks/{task_id}",
            json=kwargs,
        )
        return _parse_task(data)

    # --- Agents ---

    async def list_agents(self, conversation_id: str) -> list[Agent]:
        data = await self._get(f"/v2/conversations/{conversation_id}/agents")
        return [_parse_agent(a) for a in data.get("agents", [])]

    async def spawn_agent(
        self, conversation_id: str, role: str, model: str, **kwargs: Any
    ) -> Agent:
        body = {"role": role, "model": model, **kwargs}
        data = await self._post(
            f"/v2/conversations/{conversation_id}/agents", json=body
        )
        return _parse_agent(data)

    async def get_agent(self, conversation_id: str, agent_id: str) -> Agent:
        data = await self._get(
            f"/v2/conversations/{conversation_id}/agents/{agent_id}"
        )
        return _parse_agent(data)

    async def terminate_agent(
        self, conversation_id: str, agent_id: str, reason: str | None = None
    ) -> None:
        await self._post(
            f"/v2/conversations/{conversation_id}/agents/{agent_id}/terminate",
            json={"reason": reason},
        )

    # --- MCP ---

    async def list_mcp_servers(self) -> list[dict[str, Any]]:
        data = await self._get("/v2/mcp/servers")
        return data.get("servers", [])

    async def add_mcp_server(self, **kwargs: Any) -> dict[str, Any]:
        return await self._post("/v2/mcp/servers", json=kwargs)

    # --- Streaming ---

    async def subscribe(
        self,
        conversation_id: str,
        since_event_id: int | None = None,
        transport: str = "sse",
    ) -> AsyncIterator[Rune]:
        """Subscribe to rune events for a conversation via SSE."""
        url = f"/v2/conversations/{conversation_id}/events"
        params: dict[str, Any] = {}
        if since_event_id is not None:
            params["since_event_id"] = since_event_id

        headers: dict[str, str] = {"Accept": "text/event-stream"}
        if since_event_id is not None:
            headers["Last-Event-ID"] = str(since_event_id)

        async with self._http.stream("GET", url, params=params, headers=headers) as resp:
            resp.raise_for_status()
            data_buffer: list[str] = []

            async for line in resp.aiter_lines():
                if line.startswith("data:"):
                    data_buffer.append(line[5:].strip())
                elif line == "" and data_buffer:
                    raw = "\n".join(data_buffer)
                    data_buffer.clear()
                    try:
                        parsed = json.loads(raw)
                        yield _parse_rune(parsed)
                    except (json.JSONDecodeError, KeyError):
                        pass

    # --- HTTP primitives ---

    async def _get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        resp = await self._http.get(path, params=params)
        return self._handle_response(resp)

    async def _post(self, path: str, json: Any = None) -> Any:
        resp = await self._http.post(path, json=json)
        return self._handle_response(resp)

    async def _patch(self, path: str, json: Any = None) -> Any:
        resp = await self._http.patch(path, json=json)
        return self._handle_response(resp)

    async def _delete(self, path: str) -> None:
        resp = await self._http.delete(path)
        if resp.status_code >= 400:
            raise EchsApiError(resp.status_code, resp.text)

    def _handle_response(self, resp: httpx.Response) -> Any:
        if resp.status_code >= 400:
            try:
                body = resp.json()
            except Exception:
                body = resp.text
            raise EchsApiError(resp.status_code, body)
        if resp.status_code == 204:
            return {}
        return resp.json()


# ---------------------------------------------------------------------------
# Sync wrapper
# ---------------------------------------------------------------------------


class EchsClient:
    """Synchronous wrapper around EchsAsyncClient."""

    def __init__(
        self,
        base_url: str,
        token: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self._async = EchsAsyncClient(base_url, token=token, timeout=timeout)

    def close(self) -> None:
        asyncio.get_event_loop().run_until_complete(self._async.close())

    def __enter__(self) -> EchsClient:
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _run(self, coro: Any) -> Any:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop and loop.is_running():
            import concurrent.futures

            with concurrent.futures.ThreadPoolExecutor() as pool:
                return pool.submit(asyncio.run, coro).result()
        return asyncio.run(coro)

    # --- Conversations ---

    def create_conversation(self, **kwargs: Any) -> Conversation:
        return self._run(self._async.create_conversation(**kwargs))

    def list_conversations(self) -> list[Conversation]:
        return self._run(self._async.list_conversations())

    def get_conversation(self, conversation_id: str) -> Conversation:
        return self._run(self._async.get_conversation(conversation_id))

    def update_conversation(self, conversation_id: str, **kwargs: Any) -> Conversation:
        return self._run(self._async.update_conversation(conversation_id, **kwargs))

    def delete_conversation(self, conversation_id: str) -> None:
        return self._run(self._async.delete_conversation(conversation_id))

    # --- Messages ---

    def post_message(self, conversation_id: str, message: ConversationMessage) -> dict[str, Any]:
        return self._run(self._async.post_message(conversation_id, message))

    def list_messages(self, conversation_id: str, **kwargs: Any) -> list[dict[str, Any]]:
        return self._run(self._async.list_messages(conversation_id, **kwargs))

    # --- Lifecycle ---

    def interrupt(self, conversation_id: str) -> None:
        return self._run(self._async.interrupt(conversation_id))

    def pause(self, conversation_id: str) -> None:
        return self._run(self._async.pause(conversation_id))

    def resume(self, conversation_id: str) -> None:
        return self._run(self._async.resume(conversation_id))

    # --- Tools ---

    def list_tools(self, conversation_id: str) -> list[ToolSpec]:
        return self._run(self._async.list_tools(conversation_id))

    def register_tool(self, conversation_id: str, tool: ToolSpec) -> ToolSpec:
        return self._run(self._async.register_tool(conversation_id, tool))

    def unregister_tool(self, conversation_id: str, tool_name: str) -> None:
        return self._run(self._async.unregister_tool(conversation_id, tool_name))

    def approve_tool(self, conversation_id: str, approval: ToolApproval) -> None:
        return self._run(self._async.approve_tool(conversation_id, approval))

    # --- Checkpoints ---

    def list_checkpoints(self, conversation_id: str) -> list[Checkpoint]:
        return self._run(self._async.list_checkpoints(conversation_id))

    def create_checkpoint(self, conversation_id: str, trigger: str = "manual") -> Checkpoint:
        return self._run(self._async.create_checkpoint(conversation_id, trigger))

    def restore_checkpoint(
        self, conversation_id: str, checkpoint_id: str, dry_run: bool = False
    ) -> dict[str, Any]:
        return self._run(
            self._async.restore_checkpoint(conversation_id, checkpoint_id, dry_run)
        )

    # --- Memory ---

    def list_memories(self, conversation_id: str, **kwargs: Any) -> list[MemoryEntry]:
        return self._run(self._async.list_memories(conversation_id, **kwargs))

    def create_memory(self, conversation_id: str, entry: MemoryEntry) -> MemoryEntry:
        return self._run(self._async.create_memory(conversation_id, entry))

    def get_memory(self, conversation_id: str, memory_id: str) -> MemoryEntry:
        return self._run(self._async.get_memory(conversation_id, memory_id))

    def delete_memory(self, conversation_id: str, memory_id: str) -> None:
        return self._run(self._async.delete_memory(conversation_id, memory_id))

    def search_memories(self, conversation_id: str, query: str, **kwargs: Any) -> list[MemoryEntry]:
        return self._run(self._async.search_memories(conversation_id, query, **kwargs))

    # --- Plan ---

    def get_plan(self, conversation_id: str) -> dict[str, Any]:
        return self._run(self._async.get_plan(conversation_id))

    def update_task(self, conversation_id: str, task_id: str, **kwargs: Any) -> PlanTask:
        return self._run(self._async.update_task(conversation_id, task_id, **kwargs))

    # --- Agents ---

    def list_agents(self, conversation_id: str) -> list[Agent]:
        return self._run(self._async.list_agents(conversation_id))

    def spawn_agent(self, conversation_id: str, role: str, model: str, **kwargs: Any) -> Agent:
        return self._run(self._async.spawn_agent(conversation_id, role, model, **kwargs))

    def get_agent(self, conversation_id: str, agent_id: str) -> Agent:
        return self._run(self._async.get_agent(conversation_id, agent_id))

    def terminate_agent(
        self, conversation_id: str, agent_id: str, reason: str | None = None
    ) -> None:
        return self._run(self._async.terminate_agent(conversation_id, agent_id, reason))

    # --- MCP ---

    def list_mcp_servers(self) -> list[dict[str, Any]]:
        return self._run(self._async.list_mcp_servers())

    def add_mcp_server(self, **kwargs: Any) -> dict[str, Any]:
        return self._run(self._async.add_mcp_server(**kwargs))


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------


def _to_dict(obj: Any) -> dict[str, Any]:
    """Convert a dataclass to dict, excluding None values."""
    if hasattr(obj, "__dataclass_fields__"):
        return {k: v for k, v in asdict(obj).items() if v is not None}
    return obj


def _parse_conversation(data: dict[str, Any]) -> Conversation:
    return Conversation(
        conversation_id=data["conversation_id"],
        created_at=data.get("created_at", ""),
        last_activity_at=data.get("last_activity_at", ""),
        tools=data.get("tools", []),
        active_thread_id=data.get("active_thread_id"),
        model=data.get("model"),
        reasoning=data.get("reasoning"),
        cwd=data.get("cwd"),
        instructions=data.get("instructions"),
        coordination_mode=data.get("coordination_mode"),
    )


def _parse_tool(data: dict[str, Any]) -> ToolSpec:
    return ToolSpec(
        name=data["name"],
        description=data.get("description", ""),
        parameters=data.get("parameters", {}),
        type=data.get("type"),
        side_effects=data.get("side_effects"),
        idempotent=data.get("idempotent"),
        streaming=data.get("streaming"),
        requires_approval=data.get("requires_approval"),
        timeout=data.get("timeout"),
        max_output_bytes=data.get("max_output_bytes"),
        provenance=data.get("provenance"),
        enabled=data.get("enabled"),
    )


def _parse_checkpoint(data: dict[str, Any]) -> Checkpoint:
    return Checkpoint(
        checkpoint_id=data["checkpoint_id"],
        workspace_root=data.get("workspace_root", ""),
        trigger=data.get("trigger", "manual"),
        created_at_ms=data.get("created_at_ms", 0),
        total_bytes=data.get("total_bytes", 0),
        event_id=data.get("event_id"),
        linked_call_id=data.get("linked_call_id"),
    )


def _parse_memory(data: dict[str, Any]) -> MemoryEntry:
    return MemoryEntry(
        memory_id=data["memory_id"],
        type=data.get("type", "episodic"),
        content=data.get("content", ""),
        tags=data.get("tags", []),
        confidence=data.get("confidence", 0.0),
        privacy=data.get("privacy", "public"),
        source_rune_ids=data.get("source_rune_ids", []),
        expires_at_ms=data.get("expires_at_ms"),
    )


def _parse_task(data: dict[str, Any]) -> PlanTask:
    return PlanTask(
        id=data["id"],
        title=data.get("title", ""),
        description=data.get("description", ""),
        status=data.get("status", "pending"),
        priority=data.get("priority", "medium"),
        deps=data.get("deps", []),
        owner=data.get("owner"),
        success_criteria=data.get("success_criteria"),
    )


def _parse_agent(data: dict[str, Any]) -> Agent:
    return Agent(
        agent_id=data["agent_id"],
        role=data.get("role", ""),
        model=data.get("model", ""),
        status=data.get("status", "spawning"),
        parent_id=data.get("parent_id"),
    )


def _parse_rune(data: dict[str, Any]) -> Rune:
    return Rune(
        event_id=data.get("event_id", 0),
        rune_id=data.get("rune_id", ""),
        conversation_id=data.get("conversation_id", ""),
        kind=data.get("kind", ""),
        visibility=data.get("visibility", "public"),
        ts_ms=data.get("ts_ms", 0),
        payload=data.get("payload", {}),
        tags=data.get("tags", []),
        schema_version=data.get("schema_version", 1),
        turn_id=data.get("turn_id"),
        agent_id=data.get("agent_id"),
    )
