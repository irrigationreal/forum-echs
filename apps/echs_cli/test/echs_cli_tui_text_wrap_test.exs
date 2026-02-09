defmodule EchsCli.Tui.TextWrapTest do
  use ExUnit.Case, async: true

  alias EchsCli.Tui.TextWrap

  # --- wrap_plain/2 tests ---

  describe "wrap_plain/2" do
    test "returns single line when text fits" do
      assert TextWrap.wrap_plain("hello", 10) == ["hello"]
    end

    test "wraps at word boundary" do
      assert TextWrap.wrap_plain("hello world", 8) == ["hello ", "world"]
    end

    test "handles empty string" do
      assert TextWrap.wrap_plain("", 10) == [""]
    end

    test "preserves newlines" do
      assert TextWrap.wrap_plain("a\nb\nc", 80) == ["a", "b", "c"]
    end

    test "force-breaks long words" do
      assert TextWrap.wrap_plain("abcdefgh", 4) == ["abcd", "efgh"]
    end

    test "wraps multiple words" do
      result = TextWrap.wrap_plain("one two three four", 10)
      assert length(result) >= 2

      for line <- result do
        assert String.length(line) <= 10
      end
    end

    test "handles trailing spaces" do
      result = TextWrap.wrap_plain("hi ", 10)
      assert result == ["hi "]
    end

    test "handles multiple spaces between words" do
      result = TextWrap.wrap_plain("a  b", 10)
      assert result == ["a  b"]
    end

    test "wraps correctly at exact width" do
      result = TextWrap.wrap_plain("12345 67890", 5)
      assert length(result) >= 2
    end

    test "handles only spaces" do
      result = TextWrap.wrap_plain("   ", 2)
      assert is_list(result)
    end
  end

  # --- wrap_spans/2 tests ---

  describe "wrap_spans/2" do
    test "returns single line when spans fit" do
      result = TextWrap.wrap_spans([{"hello", []}], 10)
      assert length(result) == 1
      assert result == [[{"hello", []}]]
    end

    test "wraps at word boundary preserving styles" do
      result = TextWrap.wrap_spans([{"hello world", [color: :green]}], 8)
      assert length(result) >= 2
    end

    test "handles empty span list" do
      result = TextWrap.wrap_spans([], 10)
      assert is_list(result)
    end

    test "handles multiple styled spans" do
      result =
        TextWrap.wrap_spans(
          [
            {"Hello ", [color: :green, attributes: [:bold]]},
            {"world", [color: :white]}
          ],
          80
        )

      assert length(result) == 1
    end

    test "preserves newlines in spans" do
      result = TextWrap.wrap_spans([{"line1\nline2", []}], 80)
      assert length(result) == 2
    end

    test "force-breaks long words in spans" do
      result = TextWrap.wrap_spans([{"abcdefgh", [color: :red]}], 4)
      assert length(result) == 2
    end
  end
end
