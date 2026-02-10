defmodule EchsCore.ProviderAdapterTest do
  use ExUnit.Case, async: true

  alias EchsCore.ProviderAdapter.{CanonicalEvents, Registry, OpenAI, Anthropic}

  describe "CanonicalEvents" do
    test "assistant_delta creates correct tuple" do
      event = CanonicalEvents.assistant_delta("hello")
      assert {:assistant_delta, %{content: "hello"}} = event
    end

    test "assistant_final creates correct tuple" do
      event = CanonicalEvents.assistant_final("full text", [%{"type" => "message"}])
      assert {:assistant_final, %{content: "full text", items: [_]}} = event
    end

    test "tool_call creates correct tuple" do
      event = CanonicalEvents.tool_call("call_1", "shell", %{"cmd" => "ls"})
      assert {:tool_call, %{call_id: "call_1", name: "shell", arguments: %{"cmd" => "ls"}}} = event
    end

    test "reasoning_delta creates correct tuple" do
      event = CanonicalEvents.reasoning_delta("thinking...")
      assert {:reasoning_delta, %{content: "thinking..."}} = event
    end

    test "usage creates correct tuple" do
      event = CanonicalEvents.usage(100, 50)
      assert {:usage, %{input_tokens: 100, output_tokens: 50}} = event
    end

    test "error creates correct tuple" do
      event = CanonicalEvents.error("rate_limit", "Too many requests", true)
      assert {:error, %{type: "rate_limit", message: "Too many requests", retryable: true}} = event
    end

    test "done returns :done" do
      assert :done = CanonicalEvents.done()
    end
  end

  describe "Registry.adapter_for/1" do
    test "dispatches OpenAI models to OpenAI adapter" do
      assert {:ok, OpenAI} = Registry.adapter_for("gpt-5.3-codex")
      assert {:ok, OpenAI} = Registry.adapter_for("gpt-4o")
      assert {:ok, OpenAI} = Registry.adapter_for("o3-mini")
      assert {:ok, OpenAI} = Registry.adapter_for("o4-mini")
    end

    test "dispatches Claude models to Anthropic adapter" do
      assert {:ok, Anthropic} = Registry.adapter_for("claude-opus-4")
      assert {:ok, Anthropic} = Registry.adapter_for("claude-sonnet-4")
      assert {:ok, Anthropic} = Registry.adapter_for("claude-haiku-3.5")
      assert {:ok, Anthropic} = Registry.adapter_for("opus")
      assert {:ok, Anthropic} = Registry.adapter_for("sonnet")
      assert {:ok, Anthropic} = Registry.adapter_for("haiku")
    end

    test "returns error for unknown models" do
      assert {:error, :no_adapter} = Registry.adapter_for("unknown-model-xyz")
    end
  end

  describe "OpenAI.handles_model?/1" do
    test "handles gpt models" do
      assert OpenAI.handles_model?("gpt-5.3-codex")
      assert OpenAI.handles_model?("gpt-4o-mini")
    end

    test "handles o-series models" do
      assert OpenAI.handles_model?("o3")
      assert OpenAI.handles_model?("o3-mini")
      assert OpenAI.handles_model?("o4-mini")
    end

    test "does not handle claude models" do
      refute OpenAI.handles_model?("claude-opus-4")
      refute OpenAI.handles_model?("haiku")
    end
  end

  describe "Anthropic.handles_model?/1" do
    test "handles claude models" do
      assert Anthropic.handles_model?("claude-opus-4")
      assert Anthropic.handles_model?("claude-sonnet-4")
    end

    test "handles model aliases" do
      assert Anthropic.handles_model?("opus")
      assert Anthropic.handles_model?("sonnet")
      assert Anthropic.handles_model?("haiku")
    end

    test "does not handle gpt models" do
      refute Anthropic.handles_model?("gpt-5.3-codex")
    end
  end

  describe "OpenAI.provider_info/0" do
    test "returns provider metadata" do
      info = OpenAI.provider_info()
      assert info.name == "openai"
      assert is_list(info.models)
      assert info.supports_streaming == true
    end
  end

  describe "Anthropic.provider_info/0" do
    test "returns provider metadata" do
      info = Anthropic.provider_info()
      assert info.name == "anthropic"
      assert is_list(info.models)
      assert info.supports_streaming == true
    end
  end

  describe "Registry.all_models/0" do
    test "returns models from all adapters" do
      models = Registry.all_models()
      assert is_list(models)
      assert Enum.any?(models, &(&1.provider == "openai"))
      assert Enum.any?(models, &(&1.provider == "anthropic"))
    end
  end

  describe "Registry.register/1" do
    test "registers a custom adapter" do
      defmodule TestAdapter do
        @behaviour EchsCore.ProviderAdapter
        def start_stream(_), do: {:error, :not_implemented}
        def cancel(_), do: :ok
        def provider_info, do: %{name: "test", models: ["test-model"], supports_reasoning: false, supports_streaming: true}
        def handles_model?("test-model"), do: true
        def handles_model?(_), do: false
      end

      Registry.register(TestAdapter)
      assert {:ok, TestAdapter} = Registry.adapter_for("test-model")

      # Cleanup
      Application.put_env(:echs_core, :custom_provider_adapters,
        Application.get_env(:echs_core, :custom_provider_adapters, []) -- [TestAdapter]
      )
    end
  end
end
