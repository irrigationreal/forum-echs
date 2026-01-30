defmodule EchsServer.MessageContent do
  @moduledoc false

  @blocked_item_types ["function_call", "function_call_output", "local_shell_call"]

  @spec normalize(list()) :: {:ok, list()} | {:error, term()}
  def normalize(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_item(item) do
        {:ok, parts} when is_list(parts) ->
          {:cont, {:ok, acc ++ parts}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_item(item) when is_binary(item) do
    {:ok, [%{"type" => "input_text", "text" => item}]}
  end

  defp normalize_item(item) when is_map(item) do
    item = stringify_keys(item)

    case item do
      %{"type" => "message"} ->
        unwrap_message_item(item)

      %{"role" => _role, "content" => _content} ->
        # Chat Completions-style messages sometimes omit `"type": "message"`.
        # Accept the common user-message shape and normalize it to content parts.
        unwrap_message_item(Map.put_new(item, "type", "message"))

      %{"type" => type} when type in @blocked_item_types ->
        {:error, %{reason: "invalid content item type", type: type, got: item}}

      %{"type" => "text"} ->
        text = item["text"]

        if is_binary(text) do
          {:ok, [%{"type" => "input_text", "text" => text}]}
        else
          {:error, %{reason: "invalid text content item", got: item}}
        end

      %{"type" => type} when is_binary(type) and type != "" ->
        {:ok, [item]}

      _ ->
        {:error, %{reason: "invalid content item", got: item}}
    end
  end

  defp normalize_item(other) do
    {:error, %{reason: "invalid content item", got: other}}
  end

  defp unwrap_message_item(item) do
    role = item["role"]

    cond do
      role not in [nil, "user"] ->
        {:error, %{reason: "only user message items are allowed in content lists", got: item}}

      true ->
        normalize_message_content(item["content"])
    end
  end

  defp normalize_message_content(content) when is_binary(content) do
    {:ok, [%{"type" => "input_text", "text" => content}]}
  end

  defp normalize_message_content(content) when is_map(content) do
    normalize_message_content([content])
  end

  defp normalize_message_content(content) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_item(item) do
        {:ok, parts} ->
          # A nested `{"type":"message"}` should never become a content part.
          if Enum.any?(parts, fn p -> is_map(p) and p["type"] == "message" end) do
            {:halt,
             {:error,
              %{
                reason: "nested message items are not supported in message content",
                got: item
              }}}
          else
            {:cont, {:ok, acc ++ parts}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_message_content(other) do
    {:error, %{reason: "invalid message content", got: other}}
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), v)
    end)
  end

  defp stringify_keys(other), do: other
end
