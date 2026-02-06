defmodule EchsCore.Tools.CodexForum do
  @moduledoc """
  Codex Forum toolset.

  Exposes forum operations as function tools backed by the Codex Forum HTTP API.
  """

  @default_base_url "http://localhost:4310"
  @default_api_prefix ""
  @impersonation_ttl_seconds 600
  @token_cache :echs_codex_forum_token_cache

  @tool_names [
    "forum_list_forums",
    "forum_list_topics",
    "forum_get_topic",
    "forum_list_posts",
    "forum_create_topic",
    "forum_reply",
    "forum_list_topic_identities",
    "forum_list_users",
    "forum_get_identity"
  ]

  def tool_names, do: @tool_names

  def specs do
    [
      list_forums_spec(),
      list_topics_spec(),
      get_topic_spec(),
      list_posts_spec(),
      create_topic_spec(),
      reply_spec(),
      list_topic_identities_spec(),
      list_users_spec(),
      get_identity_spec()
    ]
  end

  def spec_by_name(name) do
    Enum.find(specs(), fn spec -> spec["name"] == name end)
  end

  def execute(name, args) do
    case name do
      "forum_list_forums" -> list_forums(args)
      "forum_list_topics" -> list_topics(args)
      "forum_get_topic" -> get_topic(args)
      "forum_list_posts" -> list_posts(args)
      "forum_create_topic" -> create_topic(args)
      "forum_reply" -> reply(args)
      "forum_list_topic_identities" -> list_topic_identities(args)
      "forum_list_users" -> list_users(args)
      "forum_get_identity" -> get_identity(args)
      _ -> {:error, "Unknown codex forum tool: #{name}"}
    end
  end

  def list_forums(_args) do
    with {:ok, token} <- require_base_token(),
         {:ok, data} <- request("/forums", token: token) do
      {:ok, data}
    end
  end

  def list_topics(args) do
    forum_id = get_arg(args, "forumId")

    with {:ok, token} <- require_base_token(),
         {:ok, forum_id} <- require_arg(forum_id, "forumId"),
         {:ok, data} <-
           request(
             "/forums/#{forum_id}/topics" <> pagination_query(args, %{page: 1, pageSize: 50}),
             token: token
           ) do
      {:ok, data}
    end
  end

  def get_topic(args) do
    topic_id = get_arg(args, "topicId")

    with {:ok, token} <- require_base_token(),
         {:ok, topic_id} <- require_arg(topic_id, "topicId"),
         {:ok, data} <- request("/topics/#{topic_id}", token: token) do
      {:ok, data}
    end
  end

  def list_posts(args) do
    topic_id = get_arg(args, "topicId")

    with {:ok, token} <- require_base_token(),
         {:ok, topic_id} <- require_arg(topic_id, "topicId"),
         {:ok, data} <-
           request(
             "/topics/#{topic_id}/posts" <> pagination_query(args, %{page: 1, pageSize: 50}),
             token: token
           ) do
      {:ok, data}
    end
  end

  def create_topic(args) do
    forum_id = get_arg(args, "forumId")
    title = get_arg(args, "title")
    body = get_arg(args, "body")
    model = get_arg(args, "model")
    reasoning_effort = get_arg(args, "reasoningEffort")
    author_identity_id = get_arg(args, "authorIdentityId")

    with {:ok, token} <- resolve_token(author_identity_id),
         {:ok, forum_id} <- require_arg(forum_id, "forumId"),
         {:ok, title} <- require_arg(title, "title"),
         {:ok, body} <- require_arg(body, "body"),
         {:ok, data} <-
           request(
             "/forums/#{forum_id}/topics",
             method: :post,
             body:
               compact_map(%{
                 "title" => title,
                 "body" => body,
                 "model" => model,
                 "reasoningEffort" => reasoning_effort
               }),
             token: token
           ) do
      {:ok, data}
    end
  end

  def reply(args) do
    topic_id = get_arg(args, "topicId")
    body = get_arg(args, "body")
    parent_post_id = get_arg(args, "parentPostId")
    author_identity_id = get_arg(args, "authorIdentityId")

    with {:ok, token} <- resolve_token(author_identity_id),
         {:ok, topic_id} <- require_arg(topic_id, "topicId"),
         {:ok, body} <- require_arg(body, "body"),
         {:ok, data} <-
           request(
             "/topics/#{topic_id}/posts",
             method: :post,
             body:
               compact_map(%{
                 "body" => body,
                 "parentPostId" => parent_post_id
               }),
             token: token
           ) do
      {:ok, data}
    end
  end

  def list_topic_identities(args) do
    topic_id = get_arg(args, "topicId")

    with {:ok, token} <- require_base_token(),
         {:ok, topic_id} <- require_arg(topic_id, "topicId"),
         {:ok, data} <-
           request(
             "/topics/#{topic_id}/identities" <>
               pagination_query(args, %{page: 1, pageSize: 200}),
             token: token
           ) do
      {:ok, data}
    end
  end

  def list_users(args) do
    page = get_int_arg(args, "page", 1)
    page_size = get_int_arg(args, "pageSize", 50)
    kind = get_arg(args, "kind")
    all_pages = get_bool_arg(args, "allPages", false)

    with {:ok, token} <- require_base_token(),
         {:ok, data} <- fetch_users_pages(token, page, page_size, all_pages) do
      items = if kind, do: Enum.filter(data, fn item -> item["kind"] == kind end), else: data

      {:ok,
       %{
         "items" => items,
         "total" => length(items),
         "page" => page,
         "pageSize" => page_size,
         "kind" => kind,
         "allPages" => all_pages
       }}
    end
  end

  def get_identity(args) do
    identity_id = get_arg(args, "identityId")

    with {:ok, token} <- require_base_token(),
         {:ok, identity_id} <- require_arg(identity_id, "identityId"),
         {:ok, data} <- request("/identities/#{identity_id}", token: token) do
      {:ok, data}
    end
  end

  defp fetch_users_pages(token, page, page_size, all_pages) do
    fetch_page = fn page_num ->
      request(
        "/admin/users?" <> URI.encode_query(%{"page" => page_num, "pageSize" => page_size}),
        token: token
      )
    end

    with {:ok, first} <- fetch_page.(page) do
      items = List.wrap(first["items"])

      if all_pages do
        collect_pages(fetch_page, page + 1, page_size, items)
      else
        {:ok, items}
      end
    end
  end

  defp collect_pages(fetch_page, page, page_size, acc) do
    case fetch_page.(page) do
      {:ok, data} ->
        items = List.wrap(data["items"])

        if length(items) < page_size do
          {:ok, acc ++ items}
        else
          collect_pages(fetch_page, page + 1, page_size, acc ++ items)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_forums_spec do
    %{
      "type" => "function",
      "name" => "forum_list_forums",
      "description" => "List all forums visible to the current token.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      }
    }
  end

  defp list_topics_spec do
    %{
      "type" => "function",
      "name" => "forum_list_topics",
      "description" => "List topics within a forum.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "forumId" => %{"type" => "string", "description" => "Forum id"},
          "page" => %{"type" => "integer", "description" => "Page (default: 1)"},
          "pageSize" => %{"type" => "integer", "description" => "Page size (default: 50)"}
        },
        "required" => ["forumId"],
        "additionalProperties" => false
      }
    }
  end

  defp get_topic_spec do
    %{
      "type" => "function",
      "name" => "forum_get_topic",
      "description" => "Fetch a single topic by id.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "topicId" => %{"type" => "string", "description" => "Topic id"}
        },
        "required" => ["topicId"],
        "additionalProperties" => false
      }
    }
  end

  defp list_posts_spec do
    %{
      "type" => "function",
      "name" => "forum_list_posts",
      "description" => "List posts in a topic.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "topicId" => %{"type" => "string", "description" => "Topic id"},
          "page" => %{"type" => "integer", "description" => "Page (default: 1)"},
          "pageSize" => %{"type" => "integer", "description" => "Page size (default: 50)"}
        },
        "required" => ["topicId"],
        "additionalProperties" => false
      }
    }
  end

  defp create_topic_spec do
    %{
      "type" => "function",
      "name" => "forum_create_topic",
      "description" =>
        "Create a new topic in a forum. Optionally impersonate another identity by providing authorIdentityId (requires admin token).",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "forumId" => %{"type" => "string", "description" => "Forum id"},
          "title" => %{"type" => "string", "description" => "Topic title"},
          "body" => %{"type" => "string", "description" => "Topic body"},
          "model" => %{"type" => "string", "description" => "Model override"},
          "reasoningEffort" => %{"type" => "string", "description" => "Reasoning effort override"},
          "authorIdentityId" => %{
            "type" => "string",
            "description" => "Identity id to impersonate (admin only)"
          }
        },
        "required" => ["forumId", "title", "body"],
        "additionalProperties" => false
      }
    }
  end

  defp reply_spec do
    %{
      "type" => "function",
      "name" => "forum_reply",
      "description" =>
        "Reply in a topic. Optionally impersonate another identity by providing authorIdentityId (requires admin token).",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "topicId" => %{"type" => "string", "description" => "Topic id"},
          "body" => %{"type" => "string", "description" => "Reply body"},
          "parentPostId" => %{"type" => "string", "description" => "Parent post id"},
          "authorIdentityId" => %{
            "type" => "string",
            "description" => "Identity id to impersonate (admin only)"
          }
        },
        "required" => ["topicId", "body"],
        "additionalProperties" => false
      }
    }
  end

  defp list_topic_identities_spec do
    %{
      "type" => "function",
      "name" => "forum_list_topic_identities",
      "description" => "List identities participating in a topic.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "topicId" => %{"type" => "string", "description" => "Topic id"},
          "page" => %{"type" => "integer", "description" => "Page (default: 1)"},
          "pageSize" => %{"type" => "integer", "description" => "Page size (default: 200)"}
        },
        "required" => ["topicId"],
        "additionalProperties" => false
      }
    }
  end

  defp list_users_spec do
    %{
      "type" => "function",
      "name" => "forum_list_users",
      "description" =>
        "List users (admin only). Use kind=\"robot\" to filter robots. Set allPages=true to retrieve all pages.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "page" => %{"type" => "integer", "description" => "Page (default: 1)"},
          "pageSize" => %{"type" => "integer", "description" => "Page size (default: 50)"},
          "kind" => %{"type" => "string", "description" => "User kind filter"},
          "allPages" => %{"type" => "boolean", "description" => "Load all pages"}
        },
        "required" => [],
        "additionalProperties" => false
      }
    }
  end

  defp get_identity_spec do
    %{
      "type" => "function",
      "name" => "forum_get_identity",
      "description" => "Fetch a single identity by id.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "identityId" => %{"type" => "string", "description" => "Identity id"}
        },
        "required" => ["identityId"],
        "additionalProperties" => false
      }
    }
  end

  defp resolve_token(nil), do: require_base_token()

  defp resolve_token(identity_id) do
    case get_impersonation_token(identity_id) do
      {:ok, token} -> {:ok, token}
      {:error, _} = error -> error
    end
  end

  defp require_base_token do
    case base_token() do
      nil ->
        {:error, "Missing forum auth token."}

      token ->
        {:ok, token}
    end
  end

  defp base_token do
    # Forum tools can run without a token if the forum server is configured
    # to accept internal robot requests.
    System.get_env("CODEX_FORUM_MCP_TOKEN") ||
      System.get_env("CODEX_FORUM_TOKEN")
  end

  defp get_impersonation_token(identity_id) do
    identity_id = to_string(identity_id)

    case cached_token(identity_id) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        with {:ok, base_token} <- require_base_token(),
             {:ok, token} <- create_impersonation_token(base_token, identity_id) do
          {:ok, token}
        end
    end
  end

  defp cached_token(identity_id) do
    table = ensure_cache_table()
    now = System.system_time(:millisecond)

    case :ets.lookup(table, identity_id) do
      [{^identity_id, token, expires_at_ms}] when expires_at_ms > now ->
        {:ok, token}

      [{^identity_id, _token, _expires_at_ms}] ->
        :ets.delete(table, identity_id)
        :miss

      _ ->
        :miss
    end
  end

  defp cache_token(identity_id, token, expires_at_ms) do
    table = ensure_cache_table()
    :ets.insert(table, {identity_id, token, expires_at_ms})
    :ok
  end

  defp ensure_cache_table do
    case :ets.whereis(@token_cache) do
      :undefined ->
        :ets.new(@token_cache, [:named_table, :public, :set, read_concurrency: true])

      tid ->
        tid
    end
  end

  defp create_impersonation_token(base_token, identity_id) do
    expires_at = DateTime.utc_now() |> DateTime.add(@impersonation_ttl_seconds, :second)
    expires_at_iso = DateTime.to_iso8601(expires_at)
    expires_at_ms = DateTime.to_unix(expires_at, :millisecond)

    payload = %{
      "label" => "echs:#{identity_id}",
      "impersonatedIdentityId" => identity_id,
      "scopes" => ["read", "write"],
      "expiresAt" => expires_at_iso
    }

    with {:ok, data} <-
           request("/impersonation-tokens", method: :post, body: payload, token: base_token),
         token when is_binary(token) <- data["token"] do
      cache_token(identity_id, token, expires_at_ms - 5_000)
      {:ok, token}
    else
      {:ok, _} -> {:error, "Failed to create impersonation token."}
      {:error, _} = error -> error
      _ -> {:error, "Failed to create impersonation token."}
    end
  end

  defp pagination_query(args, defaults) do
    page = get_int_arg(args, "page", defaults.page)
    page_size = get_int_arg(args, "pageSize", defaults.pageSize)

    "?" <>
      URI.encode_query(%{
        "page" => page,
        "pageSize" => page_size
      })
  end

  defp get_arg(args, key) do
    Map.get(args, key) || maybe_get_atom(args, key)
  end

  defp maybe_get_atom(args, key) do
    case key_to_atom(key) do
      nil -> nil
      atom -> Map.get(args, atom)
    end
  end

  defp key_to_atom("forumId"), do: :forumId
  defp key_to_atom("topicId"), do: :topicId
  defp key_to_atom("identityId"), do: :identityId
  defp key_to_atom("authorIdentityId"), do: :authorIdentityId
  defp key_to_atom("parentPostId"), do: :parentPostId
  defp key_to_atom("pageSize"), do: :pageSize
  defp key_to_atom("reasoningEffort"), do: :reasoningEffort
  defp key_to_atom("allPages"), do: :allPages
  defp key_to_atom("page"), do: :page
  defp key_to_atom("kind"), do: :kind
  defp key_to_atom("model"), do: :model
  defp key_to_atom("title"), do: :title
  defp key_to_atom("body"), do: :body
  defp key_to_atom(_), do: nil

  defp get_int_arg(args, key, default) do
    value = get_arg(args, key)

    try do
      cond do
        is_integer(value) -> value
        is_float(value) -> trunc(value)
        is_binary(value) -> String.to_integer(value)
        true -> default
      end
    rescue
      _ -> default
    end
  end

  defp get_bool_arg(args, key, default) do
    value = get_arg(args, key)

    cond do
      is_boolean(value) -> value
      is_binary(value) -> value in ["true", "1", "yes"]
      true -> default
    end
  end

  defp require_arg(nil, name), do: {:error, "Missing required field #{name}."}
  defp require_arg("", name), do: {:error, "Missing required field #{name}."}
  defp require_arg(value, _name), do: {:ok, value}

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp request(path, opts) do
    method = Keyword.get(opts, :method, :get)
    body = Keyword.get(opts, :body)
    token = Keyword.get(opts, :token)

    url = api_base_url() <> normalize_path(path)
    headers = build_headers(token)

    req_opts = [method: method, url: url, headers: headers]
    req_opts = if is_nil(body), do: req_opts, else: Keyword.put(req_opts, :json, body)

    case Req.request(req_opts) do
      {:ok, %{status: status, body: data}} when status in 200..299 ->
        {:ok, data}

      {:ok, %{status: status, body: data}} ->
        {:error, "API #{status}: #{inspect(data)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers(nil), do: build_headers("")

  defp build_headers(token) do
    base = [{"accept", "application/json"}]

    # Internal marker understood by Codex Forum: if enabled server-side,
    # this bypasses the need for an auth token.
    base = [{"x-codex-forum-internal-robot", "1"} | base]

    if is_binary(token) and token != "" do
      [{"authorization", "Bearer #{token}"} | base]
    else
      base
    end
  end

  defp api_base_url do
    base = System.get_env("CODEX_FORUM_API_BASE_URL") || @default_base_url
    prefix = System.get_env("CODEX_FORUM_API_PREFIX") || @default_api_prefix

    normalize_base(base) <> normalize_prefix(prefix)
  end

  defp normalize_base(value) do
    String.trim_trailing(value, "/")
  end

  defp normalize_prefix(value) do
    cond do
      value in [nil, "", "/"] -> ""
      String.starts_with?(value, "/") -> value
      true -> "/" <> value
    end
  end

  defp normalize_path(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end
end
