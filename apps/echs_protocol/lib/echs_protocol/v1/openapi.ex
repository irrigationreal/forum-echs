defmodule EchsProtocol.V1.OpenAPI do
  @moduledoc """
  OpenAPI spec for the ECHS HTTP daemon (v1).

  This is intentionally hand-written to keep the dependency surface small.
  """

  @spec spec() :: map()
  def spec do
    %{
      openapi: "3.1.0",
      info: %{
        title: "ECHS (Elixir Codex Harness Server)",
        version: "0.1.0",
        description:
          "Daemon + wire API for managing Codex-style tool-loop threads (sessions), streaming events via SSE."
      },
      servers: [
        %{url: "http://localhost:4000"}
      ],
      paths: paths(),
      components: %{
        securitySchemes: %{
          bearerAuth: %{
            type: "http",
            scheme: "bearer",
            description:
              "Optional. If ECHS_API_TOKEN is set on the server, requests must include Authorization: Bearer <token>."
          }
        },
        schemas: schemas()
      }
    }
  end

  defp paths do
    %{
      "/healthz" => %{
        get: %{
          summary: "Health check",
          responses: %{
            "200" => json_response("OK", %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}})
          }
        }
      },
      "/openapi.json" => %{
        get: %{
          summary: "OpenAPI spec",
          responses: %{"200" => json_response("OpenAPI spec", %{"type" => "object"})}
        }
      },
      "/v1/uploads" => %{
        post: %{
          summary: "Upload an image and get an input_image content item",
          requestBody: %{
            required: true,
            content: %{
              "multipart/form-data" => %{
                schema: %{
                  type: "object",
                  properties: %{
                    file: %{type: "string", format: "binary"}
                  },
                  required: ["file"]
                }
              }
            }
          },
          responses: %{
            "201" => %{
              description: "Upload created",
              content: %{
                "application/json" => %{
                  schema: %{"$ref" => "#/components/schemas/UploadResponse"}
                }
              }
            }
          }
        }
      },
      "/v1/threads" => %{
        post: %{
          summary: "Create a thread",
          requestBody: %{
            required: false,
            content: %{
              "application/json" => %{
                schema: %{"$ref" => "#/components/schemas/ThreadCreateRequest"}
              }
            }
          },
          responses: %{
            "201" => %{
              description: "Thread created",
              content: %{
                "application/json" => %{
                  schema: %{"$ref" => "#/components/schemas/ThreadCreateResponse"}
                }
              }
            }
          }
        },
        get: %{
          summary: "List threads (with metadata)",
          responses: %{
            "200" => %{
              description: "Thread list",
              content: %{
                "application/json" => %{
                  schema: %{"$ref" => "#/components/schemas/ThreadListResponse"}
                }
              }
            }
          }
        }
      },
      "/v1/threads/{thread_id}" => %{
        parameters: [
          %{
            name: "thread_id",
            in: "path",
            required: true,
            schema: %{"$ref" => "#/components/schemas/ThreadId"}
          }
        ],
        get: %{
          summary: "Get thread state (sanitized)",
          responses: %{
            "200" => %{
              description: "Thread state",
              content: %{
                "application/json" => %{
                  schema: %{"$ref" => "#/components/schemas/ThreadGetResponse"}
                }
              }
            },
            "404" => json_error_response("Thread not found")
          }
        },
        patch: %{
          summary: "Update thread config",
          requestBody: %{
            required: true,
            content: %{
              "application/json" => %{
                schema: %{"$ref" => "#/components/schemas/ThreadPatchRequest"}
              }
            }
          },
          responses: %{
            "200" => json_response("Updated", %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}),
            "404" => json_error_response("Thread not found")
          }
        },
        delete: %{
          summary: "Kill a thread",
          responses: %{
            "200" => json_response("Killed", %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}),
            "404" => json_error_response("Thread not found")
          }
        }
      },
      "/v1/threads/{thread_id}/messages" => %{
        parameters: [
          %{
            name: "thread_id",
            in: "path",
            required: true,
            schema: %{"$ref" => "#/components/schemas/ThreadId"}
          }
        ],
        post: %{
          summary: "Enqueue a message (async) and return message_id",
          requestBody: %{
            required: true,
            content: %{
              "application/json" => %{
                schema: %{"$ref" => "#/components/schemas/MessageEnqueueRequest"}
              }
            }
          },
          responses: %{
            "202" => %{
              description: "Accepted",
              content: %{
                "application/json" => %{
                  schema: %{"$ref" => "#/components/schemas/MessageEnqueueResponse"}
                }
              }
            },
            "404" => json_error_response("Thread not found"),
            "409" => json_error_response("Thread is paused")
          }
        }
      },
      "/v1/threads/{thread_id}/events" => %{
        parameters: [
          %{
            name: "thread_id",
            in: "path",
            required: true,
            schema: %{"$ref" => "#/components/schemas/ThreadId"}
          }
        ],
        get: %{
          summary: "Server-Sent Events stream for thread events",
          responses: %{
            "200" => %{
              description: "SSE stream (text/event-stream)",
              content: %{
                "text/event-stream" => %{
                  schema: %{
                    type: "string",
                    description:
                      "Each event is sent as `event: <type>` + `data: <json>` lines. Turn events include message_id."
                  }
                }
              }
            },
            "404" => json_error_response("Thread not found")
          }
        }
      },
      "/v1/threads/{thread_id}/interrupt" => post_ok("Interrupt current turn"),
      "/v1/threads/{thread_id}/pause" => post_ok("Pause thread"),
      "/v1/threads/{thread_id}/resume" => post_ok("Resume thread")
    }
  end

  defp post_ok(summary) do
    %{
      parameters: [
        %{
          name: "thread_id",
          in: "path",
          required: true,
          schema: %{"$ref" => "#/components/schemas/ThreadId"}
        }
      ],
      post: %{
        summary: summary,
        responses: %{
          "200" =>
            json_response("OK", %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}),
          "404" => json_error_response("Thread not found")
        }
      }
    }
  end

  defp schemas do
    %{
      ThreadId: %{type: "string", pattern: "^thr_[0-9a-f]+$"},
      MessageId: %{type: "string"},
      ISO8601: %{type: ["string", "null"], format: "date-time"},
      JSONValue: %{
        description: "Arbitrary JSON value",
        oneOf: [
          %{type: "string"},
          %{type: "number"},
          %{type: "integer"},
          %{type: "boolean"},
          %{type: "object"},
          %{type: "array"},
          %{type: "null"}
        ]
      },
      ThreadCreateRequest: %{
        type: "object",
        properties: %{
          thread_id: %{"$ref" => "#/components/schemas/ThreadId"},
          cwd: %{type: "string"},
          model: %{type: "string"},
          reasoning: %{type: "string"},
          instructions: %{type: "string"},
          coordination_mode: %{type: "string", enum: ["hierarchical", "blackboard", "peer"]},
          tools: %{
            type: "array",
            description: "Tool patch list like ['-apply_patch', '+shell'] or full tool specs as objects.",
            items: %{oneOf: [%{type: "string"}, %{type: "object"}]}
          }
        },
        additionalProperties: false
      },
      ThreadCreateResponse: %{
        type: "object",
        properties: %{
          thread_id: %{"$ref" => "#/components/schemas/ThreadId"}
        },
        required: ["thread_id"],
        additionalProperties: false
      },
      ThreadSummary: %{
        type: "object",
        properties: %{
          thread_id: %{"$ref" => "#/components/schemas/ThreadId"},
          parent_thread_id: %{type: ["string", "null"]},
          created_at: %{"$ref" => "#/components/schemas/ISO8601"},
          last_activity_at: %{"$ref" => "#/components/schemas/ISO8601"},
          model: %{type: "string"},
          reasoning: %{type: "string"},
          cwd: %{type: "string"},
          status: %{type: "string", enum: ["idle", "running", "paused"]},
          current_message_id: %{oneOf: [%{"$ref" => "#/components/schemas/MessageId"}, %{type: "null"}]},
          current_turn_started_at: %{"$ref" => "#/components/schemas/ISO8601"},
          queued_turns: %{type: "integer"},
          steer_queue: %{type: "integer"},
          history_items: %{type: "integer"},
          coordination_mode: %{type: "string", enum: ["hierarchical", "blackboard", "peer"]},
          tools: %{type: "array", items: %{type: "string"}},
          children: %{type: "array", items: %{type: "string"}}
        },
        required: ["thread_id", "created_at", "last_activity_at", "status"],
        additionalProperties: true
      },
      ThreadListResponse: %{
        type: "object",
        properties: %{
          threads: %{type: "array", items: %{"$ref" => "#/components/schemas/ThreadSummary"}}
        },
        required: ["threads"],
        additionalProperties: false
      },
      ThreadGetResponse: %{
        type: "object",
        properties: %{
          thread_id: %{"$ref" => "#/components/schemas/ThreadId"},
          state: %{"$ref" => "#/components/schemas/ThreadSummary"}
        },
        required: ["thread_id", "state"],
        additionalProperties: false
      },
      ThreadPatchRequest: %{
        type: "object",
        properties: %{
          config: %{
            type: "object",
            description:
              "Config keys: cwd, model, reasoning, instructions, tools. Keys must be strings in payload.",
            additionalProperties: %{"$ref" => "#/components/schemas/JSONValue"}
          }
        },
        additionalProperties: true
      },
      MessageContentItem: %{
        type: "object",
        properties: %{
          type: %{type: "string"},
          text: %{type: "string"},
          image_url: %{type: "string"}
        },
        additionalProperties: true
      },
      MessageEnqueueRequest: %{
        type: "object",
        properties: %{
          mode: %{type: "string", enum: ["queue", "steer"]},
          message_id: %{"$ref" => "#/components/schemas/MessageId"},
          configure: %{type: "object", additionalProperties: %{"$ref" => "#/components/schemas/JSONValue"}},
          content: %{
            description:
              "Either a plain string, or a list of Responses content items (e.g. input_text + input_image).",
            oneOf: [
              %{type: "string"},
              %{type: "array", items: %{"$ref" => "#/components/schemas/MessageContentItem"}}
            ]
          },
          text: %{type: "string", description: "Legacy alias for content when content is a string"}
        },
        additionalProperties: false
      },
      MessageEnqueueResponse: %{
        type: "object",
        properties: %{
          ok: %{type: "boolean"},
          thread_id: %{"$ref" => "#/components/schemas/ThreadId"},
          message_id: %{"$ref" => "#/components/schemas/MessageId"}
        },
        required: ["ok", "thread_id", "message_id"],
        additionalProperties: false
      },
      UploadResponse: %{
        type: "object",
        properties: %{
          upload_id: %{type: "string"},
          kind: %{type: "string"},
          bytes: %{type: "integer"},
          filename: %{type: "string"},
          content_type: %{type: "string"},
          image_url: %{type: "string"},
          content: %{"$ref" => "#/components/schemas/MessageContentItem"}
        },
        required: ["upload_id", "kind", "bytes", "content_type", "image_url", "content"],
        additionalProperties: false
      },
      ErrorResponse: %{
        type: "object",
        properties: %{
          error: %{type: "string"},
          details: %{type: "object", additionalProperties: %{"$ref" => "#/components/schemas/JSONValue"}}
        },
        required: ["error"],
        additionalProperties: false
      }
    }
  end

  defp json_response(description, schema) do
    %{
      description: description,
      content: %{
        "application/json" => %{
          schema: schema
        }
      }
    }
  end

  defp json_error_response(description) do
    %{
      description: description,
      content: %{
        "application/json" => %{
          schema: %{"$ref" => "#/components/schemas/ErrorResponse"}
        }
      }
    }
  end
end

