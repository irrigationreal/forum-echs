"""Tests for the ECHS Python SDK client."""

from __future__ import annotations

import pytest
import httpx
import respx

from echs_sdk import EchsAsyncClient, Conversation, ToolSpec, MemoryEntry, Agent
from echs_sdk.client import EchsApiError


BASE_URL = "http://localhost:4000"


@pytest.fixture
def async_client():
    return EchsAsyncClient(BASE_URL, token="test-token")


# ---------------------------------------------------------------------------
# Conversations
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_create_conversation(async_client: EchsAsyncClient):
    respx.post(f"{BASE_URL}/v2/conversations").mock(
        return_value=httpx.Response(
            200,
            json={
                "conversation_id": "conv_1",
                "created_at": "2026-01-01T00:00:00Z",
                "last_activity_at": "2026-01-01T00:00:00Z",
                "model": "gpt-5.3-codex",
                "tools": [],
            },
        )
    )
    conv = await async_client.create_conversation(model="gpt-5.3-codex")
    assert isinstance(conv, Conversation)
    assert conv.conversation_id == "conv_1"
    assert conv.model == "gpt-5.3-codex"


@respx.mock
@pytest.mark.asyncio
async def test_list_conversations(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/conversations").mock(
        return_value=httpx.Response(200, json={"conversations": []})
    )
    result = await async_client.list_conversations()
    assert result == []


@respx.mock
@pytest.mark.asyncio
async def test_get_conversation(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/conversations/conv_1").mock(
        return_value=httpx.Response(
            200,
            json={
                "conversation_id": "conv_1",
                "created_at": "2026-01-01T00:00:00Z",
                "last_activity_at": "2026-01-01T00:00:00Z",
                "tools": [],
            },
        )
    )
    conv = await async_client.get_conversation("conv_1")
    assert conv.conversation_id == "conv_1"


@respx.mock
@pytest.mark.asyncio
async def test_delete_conversation(async_client: EchsAsyncClient):
    respx.delete(f"{BASE_URL}/v2/conversations/conv_1").mock(
        return_value=httpx.Response(204)
    )
    await async_client.delete_conversation("conv_1")


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_post_message(async_client: EchsAsyncClient):
    respx.post(f"{BASE_URL}/v2/conversations/conv_1/messages").mock(
        return_value=httpx.Response(200, json={"message_id": "msg_1"})
    )
    from echs_sdk import ConversationMessage

    result = await async_client.post_message(
        "conv_1", ConversationMessage(content="Hello")
    )
    assert result["message_id"] == "msg_1"


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_interrupt(async_client: EchsAsyncClient):
    respx.post(f"{BASE_URL}/v2/conversations/conv_1/interrupt").mock(
        return_value=httpx.Response(200, json={})
    )
    await async_client.interrupt("conv_1")


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_list_tools(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/conversations/conv_1/tools").mock(
        return_value=httpx.Response(
            200,
            json={"tools": [{"name": "bash", "description": "Run bash", "parameters": {}}]},
        )
    )
    tools = await async_client.list_tools("conv_1")
    assert len(tools) == 1
    assert isinstance(tools[0], ToolSpec)
    assert tools[0].name == "bash"


@respx.mock
@pytest.mark.asyncio
async def test_register_tool(async_client: EchsAsyncClient):
    tool = ToolSpec(name="custom", description="Custom tool", parameters={})
    respx.post(f"{BASE_URL}/v2/conversations/conv_1/tools").mock(
        return_value=httpx.Response(
            201,
            json={"name": "custom", "description": "Custom tool", "parameters": {}},
        )
    )
    result = await async_client.register_tool("conv_1", tool)
    assert result.name == "custom"


# ---------------------------------------------------------------------------
# Checkpoints
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_list_checkpoints(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/conversations/conv_1/checkpoints").mock(
        return_value=httpx.Response(200, json={"checkpoints": []})
    )
    result = await async_client.list_checkpoints("conv_1")
    assert result == []


# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_search_memories(async_client: EchsAsyncClient):
    entry = {
        "memory_id": "mem_1",
        "type": "semantic",
        "content": "test fact",
        "tags": [],
        "confidence": 0.9,
        "privacy": "public",
        "source_rune_ids": [],
    }
    respx.post(f"{BASE_URL}/v2/conversations/conv_1/memories/search").mock(
        return_value=httpx.Response(200, json={"results": [entry]})
    )
    result = await async_client.search_memories("conv_1", query="test")
    assert len(result) == 1
    assert isinstance(result[0], MemoryEntry)
    assert result[0].memory_id == "mem_1"


# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_get_plan(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/conversations/conv_1/plan").mock(
        return_value=httpx.Response(
            200, json={"tasks": [], "status_counts": {"pending": 0}}
        )
    )
    result = await async_client.get_plan("conv_1")
    assert result["tasks"] == []


# ---------------------------------------------------------------------------
# Agents
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_spawn_agent(async_client: EchsAsyncClient):
    respx.post(f"{BASE_URL}/v2/conversations/conv_1/agents").mock(
        return_value=httpx.Response(
            201,
            json={
                "agent_id": "agent_1",
                "role": "worker",
                "model": "gpt-5.3-codex",
                "status": "spawning",
            },
        )
    )
    agent = await async_client.spawn_agent("conv_1", role="worker", model="gpt-5.3-codex")
    assert isinstance(agent, Agent)
    assert agent.agent_id == "agent_1"


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_api_error(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/conversations/missing").mock(
        return_value=httpx.Response(404, json={"error": "not_found"})
    )
    with pytest.raises(EchsApiError) as exc_info:
        await async_client.get_conversation("missing")
    assert exc_info.value.status == 404


# ---------------------------------------------------------------------------
# MCP
# ---------------------------------------------------------------------------


@respx.mock
@pytest.mark.asyncio
async def test_list_mcp_servers(async_client: EchsAsyncClient):
    respx.get(f"{BASE_URL}/v2/mcp/servers").mock(
        return_value=httpx.Response(
            200, json={"servers": [{"name": "test-mcp", "status": "connected"}]}
        )
    )
    result = await async_client.list_mcp_servers()
    assert len(result) == 1
    assert result[0]["name"] == "test-mcp"
