defmodule EchsBashParserTest do
  use ExUnit.Case, async: true

  describe "parse_shell_commands/1" do
    test "accepts single simple command" do
      assert {:ok, [["ls", "-1"]]} = EchsBashParser.parse_shell_commands("ls -1")
    end

    test "accepts multiple commands with allowed operators" do
      assert {:ok, cmds} = EchsBashParser.parse_shell_commands("ls && pwd; echo 'hi there' | wc -l")

      assert cmds == [
               ["ls"],
               ["pwd"],
               ["echo", "hi there"],
               ["wc", "-l"]
             ]
    end

    test "extracts double and single quoted strings" do
      assert {:ok, [["echo", "hello world"]]} =
               EchsBashParser.parse_shell_commands(~s(echo "hello world"))

      assert {:ok, [["echo", "hi there"]]} =
               EchsBashParser.parse_shell_commands("echo 'hi there'")
    end

    test "accepts numbers as words" do
      assert {:ok, [["echo", "123", "456"]]} =
               EchsBashParser.parse_shell_commands("echo 123 456")
    end

    test "rejects parentheses and subshells" do
      assert {:error, :unsafe_construct} = EchsBashParser.parse_shell_commands("(ls)")

      assert {:error, :unsafe_construct} =
               EchsBashParser.parse_shell_commands("ls || (pwd && echo hi)")
    end

    test "rejects redirections" do
      assert {:error, :unsafe_construct} = EchsBashParser.parse_shell_commands("ls > out.txt")
    end

    test "rejects background operator" do
      assert {:error, :unsafe_construct} =
               EchsBashParser.parse_shell_commands("echo hi & echo bye")
    end

    test "rejects command substitution" do
      assert {:error, :unsafe_construct} = EchsBashParser.parse_shell_commands("echo $(pwd)")
      assert {:error, :unsafe_construct} = EchsBashParser.parse_shell_commands("echo `pwd`")
    end

    test "rejects variable expansion" do
      assert {:error, :unsafe_construct} = EchsBashParser.parse_shell_commands("echo $HOME")

      assert {:error, :unsafe_construct} =
               EchsBashParser.parse_shell_commands(~s(echo "hi $USER"))
    end

    test "rejects variable assignment prefix" do
      assert {:error, :unsafe_construct} = EchsBashParser.parse_shell_commands("FOO=bar ls")
    end

    test "rejects trailing operator parse error" do
      assert {:error, _} = EchsBashParser.parse_shell_commands("ls &&")
    end

    test "accepts concatenated flag and value" do
      assert {:ok, [["rg", "-n", "foo", "-g*.py"]]} =
               EchsBashParser.parse_shell_commands(~s(rg -n "foo" -g"*.py"))
    end
  end

  describe "is_safe_command?/1" do
    test "safe simple commands" do
      assert EchsBashParser.is_safe_command?(["ls"])
      assert EchsBashParser.is_safe_command?(["ls", "-la"])
      assert EchsBashParser.is_safe_command?(["pwd"])
      assert EchsBashParser.is_safe_command?(["cat", "file.txt"])
      assert EchsBashParser.is_safe_command?(["grep", "pattern", "file.txt"])
      assert EchsBashParser.is_safe_command?(["head", "-n", "10", "file.txt"])
      assert EchsBashParser.is_safe_command?(["tail", "-f", "log.txt"])
      assert EchsBashParser.is_safe_command?(["wc", "-l"])
    end

    test "safe git commands" do
      assert EchsBashParser.is_safe_command?(["git", "status"])
      assert EchsBashParser.is_safe_command?(["git", "log"])
      assert EchsBashParser.is_safe_command?(["git", "diff"])
      assert EchsBashParser.is_safe_command?(["git", "branch"])
      assert EchsBashParser.is_safe_command?(["git", "show"])
    end

    test "unsafe git commands" do
      refute EchsBashParser.is_safe_command?(["git", "push"])
      refute EchsBashParser.is_safe_command?(["git", "fetch"])
      refute EchsBashParser.is_safe_command?(["git", "checkout"])
    end

    test "safe find commands" do
      assert EchsBashParser.is_safe_command?(["find", ".", "-name", "*.txt"])
    end

    test "unsafe find commands" do
      refute EchsBashParser.is_safe_command?(["find", ".", "-delete"])
      refute EchsBashParser.is_safe_command?(["find", ".", "-exec", "rm", "{}", ";"])
    end

    test "safe ripgrep commands" do
      assert EchsBashParser.is_safe_command?(["rg", "pattern", "-n"])
    end

    test "unsafe ripgrep commands" do
      refute EchsBashParser.is_safe_command?(["rg", "--pre", "cmd", "pattern"])
      refute EchsBashParser.is_safe_command?(["rg", "--search-zip", "pattern"])
    end

    test "safe bash -lc commands" do
      assert EchsBashParser.is_safe_command?(["bash", "-lc", "ls"])
      assert EchsBashParser.is_safe_command?(["bash", "-lc", "ls && pwd"])
      assert EchsBashParser.is_safe_command?(["bash", "-lc", "git status"])
      assert EchsBashParser.is_safe_command?(["zsh", "-lc", "ls"])
    end

    test "unsafe bash -lc commands" do
      refute EchsBashParser.is_safe_command?(["bash", "-lc", "rm -rf /"])
      refute EchsBashParser.is_safe_command?(["bash", "-lc", "ls && rm file"])
      refute EchsBashParser.is_safe_command?(["bash", "-lc", "(ls)"])
    end

    test "safe sed commands" do
      assert EchsBashParser.is_safe_command?(["sed", "-n", "1,5p", "file.txt"])
      assert EchsBashParser.is_safe_command?(["sed", "-n", "10p", "file.txt"])
    end

    test "unsafe sed commands" do
      refute EchsBashParser.is_safe_command?(["sed", "-i", "s/foo/bar/", "file.txt"])
    end

    test "unknown commands are unsafe" do
      refute EchsBashParser.is_safe_command?(["rm", "-rf", "/"])
      refute EchsBashParser.is_safe_command?(["curl", "http://example.com"])
      refute EchsBashParser.is_safe_command?(["unknown_cmd"])
    end
  end

  describe "validate_script/1" do
    test "returns :ok for safe scripts" do
      assert :ok = EchsBashParser.validate_script("ls -la")
      assert :ok = EchsBashParser.validate_script("echo hello && pwd")
    end

    test "returns error for unsafe scripts" do
      assert {:error, _} = EchsBashParser.validate_script("echo $(pwd)")
      assert {:error, _} = EchsBashParser.validate_script("ls > file.txt")
    end
  end
end
