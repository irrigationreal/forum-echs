defmodule EchsCore.ApiV2.Spec do
  @moduledoc """
  API v2 endpoint specification.

  Defines all v2 REST endpoints, their parameters, and response shapes.
  This serves as both documentation and the source for OpenAPI generation.

  ## Endpoint Groups

  - Conversations: CRUD + lifecycle
  - Messages: send + list + get
  - Tools: registry + invocation
  - MCP: server management
  - Checkpoints: create + restore + list
  - Memory: CRUD + query
  - Plan: task graph management
  - Agents: team management
  """

  @doc """
  Return the full API v2 specification as a map suitable for OpenAPI generation.
  """
  @spec openapi_spec() :: map()
  def openapi_spec do
    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "ECHS API v2",
        "version" => "2.0.0",
        "description" => "Event-sourced Codex Harness Server API"
      },
      "paths" => paths(),
      "components" => %{
        "securitySchemes" => %{
          "bearerAuth" => %{
            "type" => "http",
            "scheme" => "bearer"
          }
        },
        "schemas" => schemas()
      },
      "security" => [%{"bearerAuth" => []}]
    }
  end

  @doc "List all endpoint paths."
  @spec endpoint_paths() :: [String.t()]
  def endpoint_paths do
    Map.keys(paths())
  end

  defp paths do
    %{
      # --- Conversations ---
      "/v2/conversations" => %{
        "post" => %{
          "summary" => "Create a conversation",
          "tags" => ["conversations"],
          "requestBody" => ref_body("CreateConversation"),
          "responses" => %{"201" => ref_response("Conversation")}
        },
        "get" => %{
          "summary" => "List conversations",
          "tags" => ["conversations"],
          "parameters" => [param_limit(), param_offset()],
          "responses" => %{"200" => ref_response("ConversationList")}
        }
      },
      "/v2/conversations/{conversation_id}" => %{
        "get" => %{
          "summary" => "Get a conversation",
          "tags" => ["conversations"],
          "parameters" => [param_conversation_id()],
          "responses" => %{"200" => ref_response("Conversation"), "404" => ref_response("Error")}
        },
        "patch" => %{
          "summary" => "Update conversation config",
          "tags" => ["conversations"],
          "parameters" => [param_conversation_id()],
          "requestBody" => ref_body("UpdateConversation"),
          "responses" => %{"200" => ref_response("Conversation")}
        },
        "delete" => %{
          "summary" => "Delete a conversation",
          "tags" => ["conversations"],
          "parameters" => [param_conversation_id()],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },

      # --- Messages ---
      "/v2/conversations/{conversation_id}/messages" => %{
        "post" => %{
          "summary" => "Send a message",
          "tags" => ["messages"],
          "parameters" => [param_conversation_id()],
          "requestBody" => ref_body("SendMessage"),
          "responses" => %{"202" => ref_response("MessageAccepted")}
        },
        "get" => %{
          "summary" => "List messages",
          "tags" => ["messages"],
          "parameters" => [param_conversation_id(), param_limit()],
          "responses" => %{"200" => ref_response("MessageList")}
        }
      },

      # --- Events ---
      "/v2/conversations/{conversation_id}/events" => %{
        "get" => %{
          "summary" => "SSE event stream",
          "tags" => ["events"],
          "parameters" => [param_conversation_id()],
          "responses" => %{"200" => %{"description" => "text/event-stream"}}
        }
      },

      # --- Lifecycle ---
      "/v2/conversations/{conversation_id}/interrupt" => %{
        "post" => %{
          "summary" => "Interrupt active turn",
          "tags" => ["lifecycle"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },
      "/v2/conversations/{conversation_id}/pause" => %{
        "post" => %{
          "summary" => "Pause conversation",
          "tags" => ["lifecycle"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },
      "/v2/conversations/{conversation_id}/resume" => %{
        "post" => %{
          "summary" => "Resume conversation",
          "tags" => ["lifecycle"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },

      # --- Tools ---
      "/v2/conversations/{conversation_id}/tools" => %{
        "get" => %{
          "summary" => "List registered tools",
          "tags" => ["tools"],
          "responses" => %{"200" => ref_response("ToolList")}
        },
        "post" => %{
          "summary" => "Register a tool",
          "tags" => ["tools"],
          "requestBody" => ref_body("RegisterTool"),
          "responses" => %{"201" => ref_response("Tool")}
        }
      },
      "/v2/conversations/{conversation_id}/tools/{tool_name}" => %{
        "delete" => %{
          "summary" => "Unregister a tool",
          "tags" => ["tools"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },
      "/v2/conversations/{conversation_id}/tools/{tool_name}/approve" => %{
        "post" => %{
          "summary" => "Approve a pending tool call",
          "tags" => ["tools"],
          "requestBody" => ref_body("ApproveToolCall"),
          "responses" => %{"200" => ref_response("Ok")}
        }
      },

      # --- MCP ---
      "/v2/mcp/servers" => %{
        "get" => %{
          "summary" => "List MCP servers",
          "tags" => ["mcp"],
          "responses" => %{"200" => ref_response("MCPServerList")}
        },
        "post" => %{
          "summary" => "Connect an MCP server",
          "tags" => ["mcp"],
          "requestBody" => ref_body("ConnectMCP"),
          "responses" => %{"201" => ref_response("MCPServer")}
        }
      },
      "/v2/mcp/servers/{server_name}" => %{
        "delete" => %{
          "summary" => "Disconnect an MCP server",
          "tags" => ["mcp"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },

      # --- Checkpoints ---
      "/v2/conversations/{conversation_id}/checkpoints" => %{
        "get" => %{
          "summary" => "List checkpoints",
          "tags" => ["checkpoints"],
          "responses" => %{"200" => ref_response("CheckpointList")}
        },
        "post" => %{
          "summary" => "Create a checkpoint",
          "tags" => ["checkpoints"],
          "requestBody" => ref_body("CreateCheckpoint"),
          "responses" => %{"201" => ref_response("Checkpoint")}
        }
      },
      "/v2/conversations/{conversation_id}/checkpoints/{checkpoint_id}/restore" => %{
        "post" => %{
          "summary" => "Restore (rewind) to a checkpoint",
          "tags" => ["checkpoints"],
          "requestBody" => ref_body("RestoreCheckpoint"),
          "responses" => %{"200" => ref_response("RewindResult")}
        }
      },

      # --- Memory ---
      "/v2/conversations/{conversation_id}/memories" => %{
        "get" => %{
          "summary" => "List memories",
          "tags" => ["memory"],
          "parameters" => [param_conversation_id(), param_limit()],
          "responses" => %{"200" => ref_response("MemoryList")}
        },
        "post" => %{
          "summary" => "Create a memory",
          "tags" => ["memory"],
          "requestBody" => ref_body("CreateMemory"),
          "responses" => %{"201" => ref_response("Memory")}
        }
      },
      "/v2/conversations/{conversation_id}/memories/{memory_id}" => %{
        "get" => %{
          "summary" => "Get a memory",
          "tags" => ["memory"],
          "responses" => %{"200" => ref_response("Memory")}
        },
        "patch" => %{
          "summary" => "Update a memory",
          "tags" => ["memory"],
          "responses" => %{"200" => ref_response("Memory")}
        },
        "delete" => %{
          "summary" => "Delete a memory",
          "tags" => ["memory"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },
      "/v2/conversations/{conversation_id}/memories/search" => %{
        "post" => %{
          "summary" => "Search memories",
          "tags" => ["memory"],
          "requestBody" => ref_body("SearchMemories"),
          "responses" => %{"200" => ref_response("MemoryList")}
        }
      },

      # --- Plan ---
      "/v2/conversations/{conversation_id}/plan" => %{
        "get" => %{
          "summary" => "Get current plan",
          "tags" => ["plan"],
          "responses" => %{"200" => ref_response("Plan")}
        },
        "post" => %{
          "summary" => "Set plan",
          "tags" => ["plan"],
          "requestBody" => ref_body("SetPlan"),
          "responses" => %{"200" => ref_response("Plan")}
        }
      },
      "/v2/conversations/{conversation_id}/plan/tasks/{task_id}" => %{
        "patch" => %{
          "summary" => "Update a task",
          "tags" => ["plan"],
          "requestBody" => ref_body("UpdateTask"),
          "responses" => %{"200" => ref_response("Task")}
        }
      },

      # --- Agents ---
      "/v2/conversations/{conversation_id}/agents" => %{
        "get" => %{
          "summary" => "List agents",
          "tags" => ["agents"],
          "responses" => %{"200" => ref_response("AgentList")}
        },
        "post" => %{
          "summary" => "Spawn an agent",
          "tags" => ["agents"],
          "requestBody" => ref_body("SpawnAgent"),
          "responses" => %{"201" => ref_response("Agent")}
        }
      },
      "/v2/conversations/{conversation_id}/agents/{agent_id}" => %{
        "get" => %{
          "summary" => "Get agent status",
          "tags" => ["agents"],
          "responses" => %{"200" => ref_response("Agent")}
        },
        "delete" => %{
          "summary" => "Terminate an agent",
          "tags" => ["agents"],
          "responses" => %{"200" => ref_response("Ok")}
        }
      },

      # --- Health / Meta ---
      "/v2/health" => %{
        "get" => %{
          "summary" => "Health check",
          "tags" => ["meta"],
          "responses" => %{"200" => ref_response("Health")}
        }
      },
      "/v2/models" => %{
        "get" => %{
          "summary" => "List available models",
          "tags" => ["meta"],
          "responses" => %{"200" => ref_response("ModelList")}
        }
      }
    }
  end

  defp schemas do
    %{
      "Rune" => %{
        "type" => "object",
        "properties" => %{
          "event_id" => %{"type" => "integer"},
          "rune_id" => %{"type" => "string"},
          "conversation_id" => %{"type" => "string"},
          "kind" => %{"type" => "string"},
          "ts_ms" => %{"type" => "integer"},
          "payload" => %{"type" => "object"}
        }
      },
      "Memory" => %{
        "type" => "object",
        "properties" => %{
          "memory_id" => %{"type" => "string"},
          "memory_type" => %{"type" => "string", "enum" => ["episodic", "semantic", "procedural", "decision"]},
          "content" => %{"type" => "string"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "confidence" => %{"type" => "number"},
          "privacy" => %{"type" => "string", "enum" => ["public", "internal", "secret"]}
        }
      },
      "Task" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "status" => %{"type" => "string", "enum" => ["pending", "running", "completed", "failed", "cancelled"]},
          "priority" => %{"type" => "string", "enum" => ["critical", "high", "medium", "low"]},
          "deps" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      },
      "Checkpoint" => %{
        "type" => "object",
        "properties" => %{
          "checkpoint_id" => %{"type" => "string"},
          "trigger" => %{"type" => "string"},
          "created_at_ms" => %{"type" => "integer"},
          "file_count" => %{"type" => "integer"},
          "total_bytes" => %{"type" => "integer"}
        }
      }
    }
  end

  defp ref_response(name), do: %{"description" => name}
  defp ref_body(name), do: %{"description" => name}

  defp param_conversation_id do
    %{"name" => "conversation_id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}
  end

  defp param_limit do
    %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer", "default" => 50}}
  end

  defp param_offset do
    %{"name" => "offset", "in" => "query", "schema" => %{"type" => "integer", "default" => 0}}
  end
end
