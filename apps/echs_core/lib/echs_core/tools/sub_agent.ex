defmodule EchsCore.Tools.SubAgent do
  @moduledoc """
  Sub-agent tools for spawning and coordinating child agents.
  """

  def spawn_spec do
    %{
      "type" => "function",
      "name" => "spawn_agent",
      "description" => "Spawn a sub-agent to work on a task. Returns agent_id.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "The task for the sub-agent to work on"
          },
          "coordination" => %{
            "type" => "string",
            "enum" => ["hierarchical", "blackboard", "peer"],
            "description" => "Coordination mode (default: hierarchical)"
          },
          "tools" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tools to give the sub-agent (default: all)"
          },
          "reasoning" => %{
            "type" => "string",
            "enum" => ["low", "medium", "high", "xhigh"],
            "description" => "Reasoning effort level (default: medium)"
          }
        },
        "required" => ["task"]
      }
    }
  end

  def send_spec do
    %{
      "type" => "function",
      "name" => "send_to_agent",
      "description" => "Send a message to a sub-agent.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "The agent ID to send to"
          },
          "message" => %{
            "type" => "string",
            "description" => "The message to send"
          },
          "interrupt" => %{
            "type" => "boolean",
            "description" => "If true, interrupt the agent's current work first"
          }
        },
        "required" => ["agent_id", "message"]
      }
    }
  end

  def wait_spec do
    %{
      "type" => "function",
      "name" => "wait_agents",
      "description" => "Wait for sub-agents to complete. Returns their results.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "agent_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of agent IDs to wait for"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["any", "all"],
            "description" => "Wait for 'any' (first) or 'all' agents (default: all)"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: 600000 = 10 min)"
          }
        },
        "required" => ["agent_ids"]
      }
    }
  end

  def blackboard_write_spec do
    %{
      "type" => "function",
      "name" => "blackboard_write",
      "description" => "Write a value to the shared blackboard.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" => "The key to write"
          },
          "value" => %{
            "description" => "The value to store (any JSON value)"
          },
          "notify_parent" => %{
            "type" => "boolean",
            "description" => "If true, notify and optionally interrupt the parent agent"
          },
          "steer_message" => %{
            "type" => "string",
            "description" => "If notify_parent, inject this message to steer the parent"
          }
        },
        "required" => ["key", "value"]
      }
    }
  end

  def blackboard_read_spec do
    %{
      "type" => "function",
      "name" => "blackboard_read",
      "description" => "Read a value from the shared blackboard.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" => "The key to read"
          }
        },
        "required" => ["key"]
      }
    }
  end

  def kill_spec do
    %{
      "type" => "function",
      "name" => "kill_agent",
      "description" => "Kill a sub-agent.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "The agent ID to kill"
          }
        },
        "required" => ["agent_id"]
      }
    }
  end
end
