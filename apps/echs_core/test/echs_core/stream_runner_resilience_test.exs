defmodule EchsCore.StreamRunnerResilienceTest do
  use ExUnit.Case, async: true

  alias EchsCore.ThreadWorker.StreamRunner

  describe "provider_name_for_model/1" do
    test "returns :openai for GPT models" do
      assert StreamRunner.provider_name_for_model("gpt-5.3-codex") == :openai
      assert StreamRunner.provider_name_for_model("gpt-5.2") == :openai
      assert StreamRunner.provider_name_for_model("gpt-4o") == :openai
      assert StreamRunner.provider_name_for_model("gpt-4o-mini") == :openai
    end

    test "returns :openai for o-series models" do
      assert StreamRunner.provider_name_for_model("o3") == :openai
      assert StreamRunner.provider_name_for_model("o3-mini") == :openai
      assert StreamRunner.provider_name_for_model("o4-mini") == :openai
    end

    test "returns :anthropic for Claude models" do
      assert StreamRunner.provider_name_for_model("claude-opus-4") == :anthropic
      assert StreamRunner.provider_name_for_model("claude-sonnet-4") == :anthropic
      assert StreamRunner.provider_name_for_model("claude-haiku-3.5") == :anthropic
    end

    test "returns :anthropic for shorthand model names" do
      assert StreamRunner.provider_name_for_model("opus") == :anthropic
      assert StreamRunner.provider_name_for_model("sonnet") == :anthropic
      assert StreamRunner.provider_name_for_model("haiku") == :anthropic
    end

    test "falls back to :openai for unknown models" do
      assert StreamRunner.provider_name_for_model("unknown-model-xyz") == :openai
    end
  end

  describe "resilience_opts/0" do
    test "returns expected default configuration" do
      opts = StreamRunner.resilience_opts()

      assert opts.max_retries == 2
      assert opts.base_delay_ms == 500
      assert opts.max_delay_ms == 15_000
      assert opts.jitter_factor == 0.25
      assert opts.rate_limit == 120
      assert opts.rate_window_ms == 60_000
      assert opts.circuit_breaker_enabled == true
      assert opts.tracing_enabled == true
    end
  end
end
