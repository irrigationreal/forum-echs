defmodule EchsCore.Tools.ApplyPatchInvocationTest do
  use ExUnit.Case, async: true

  alias EchsCore.Tools.ApplyPatchInvocation

  @patch """
*** Begin Patch
*** Add File: foo.txt
+hi
*** End Patch
"""

  test "detects direct apply_patch invocation" do
    cwd = "/tmp"
    argv = ["apply_patch", @patch]

    assert {:ok, %{patch: @patch, cwd: ^cwd}} =
             ApplyPatchInvocation.maybe_parse_verified(argv, cwd)
  end

  test "detects heredoc invocation with cd" do
    cwd = "/tmp"
    argv = [
      "bash",
      "-lc",
      "cd work && apply_patch <<'PATCH'\n#{@patch}\nPATCH"
    ]

    expected_patch = String.trim_trailing(@patch, "\n")

    assert {:ok, %{patch: ^expected_patch, cwd: resolved}} =
             ApplyPatchInvocation.maybe_parse_verified(argv, cwd)

    assert resolved == Path.expand(Path.join(cwd, "work"))
  end

  test "rejects implicit invocation" do
    cwd = "/tmp"

    assert {:error, message} =
             ApplyPatchInvocation.maybe_parse_verified([@patch], cwd)

    assert message =~ "patch detected without explicit call to apply_patch"
  end
end
