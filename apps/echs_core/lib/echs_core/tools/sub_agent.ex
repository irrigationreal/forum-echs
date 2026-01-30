defmodule EchsCore.Tools.SubAgent do
  @moduledoc """
  Sub-agent tools for spawning and coordinating child agents.
  """

  def spawn_spec do
    %{
      "type" => "function",
      "name" => "spawn_agent",
      "description" =>
        "Spawn a sub-agent for a well-scoped task. Returns the agent id to use to communicate with this agent.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" =>
              "Initial task for the new agent. Include scope, constraints, and the expected output."
          },
          "agent_type" => %{
            "type" => "string",
            "description" =>
              "Optional agent type (default, explorer, worker). Use an explicit type when delegating."
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      }
    }
  end

  def send_spec do
    %{
      "type" => "function",
      "name" => "send_input",
      "description" =>
        "Send a message to an existing agent. Use interrupt=true to redirect work immediately.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Agent id to message (from spawn_agent)."
          },
          "message" => %{
            "type" => "string",
            "description" => "Message to send to the agent."
          },
          "interrupt" => %{
            "type" => "boolean",
            "description" =>
              "When true, stop the agent's current task and handle this immediately. When false (default), queue this message."
          }
        },
        "required" => ["id", "message"],
        "additionalProperties" => false
      }
    }
  end

  def wait_spec do
    %{
      "type" => "function",
      "name" => "wait",
      "description" =>
        "Wait for agents to reach a final status. Completed statuses may include the agent's final message. Returns empty status when timed out.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Agent ids to wait on. Pass multiple ids to wait for whichever finishes first."
          },
          "timeout_ms" => %{
            "type" => "number",
            "description" =>
              "Optional timeout in milliseconds. Defaults to 600000, min 10000, max 300000. Prefer longer waits (minutes) to avoid busy polling."
          }
        },
        "required" => ["ids"],
        "additionalProperties" => false
      }
    }
  end

  def close_spec do
    %{
      "type" => "function",
      "name" => "close_agent",
      "description" =>
        "Close an agent when it is no longer needed and return its last known status.",
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Agent id to close (from spawn_agent)."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
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
          "key" => %{"type" => "string", "description" => "The key to write"},
          "value" => %{"description" => "The value to store (any JSON value)"},
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
          "key" => %{"type" => "string", "description" => "The key to read"}
        },
        "required" => ["key"]
      }
    }
  end
end
