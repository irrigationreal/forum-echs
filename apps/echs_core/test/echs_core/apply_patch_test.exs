defmodule EchsCore.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias EchsCore.Tools.ApplyPatch

  test "apply_patch accepts update hunks that end at EOF" do
    dir = Path.join(System.tmp_dir!(), "echs_apply_patch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    path = Path.join(dir, "foo.txt")
    File.write!(path, "old\n")

    patch =
      "*** Begin Patch\n" <>
        "*** Update File: foo.txt\n" <>
        "@@\n" <>
        "-old\n" <>
        "+new\n" <>
        "*** End Patch"

    result = ApplyPatch.apply(patch, cwd: dir)

    assert is_binary(result)
    assert File.read!(path) == "new\n"
  end
end
