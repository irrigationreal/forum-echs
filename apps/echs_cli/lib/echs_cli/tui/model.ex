defmodule EchsCli.Tui.Model do
  @moduledoc """
  Core data structures for the TUI application state.
  """

  defmodule Message do
    @moduledoc false

    @type role :: :user | :assistant | :tool_call | :tool_result | :system | :reasoning | :subagent_spawned | :subagent_down

    @type t :: %__MODULE__{
            id: String.t() | nil,
            role: role(),
            content: String.t(),
            tool_name: String.t() | nil,
            tool_args: String.t() | nil,
            call_id: String.t() | nil,
            status: :pending | :running | :success | :error | nil,
            timestamp: integer() | nil,
            agent_id: String.t() | nil
          }

    defstruct id: nil,
              role: :assistant,
              content: "",
              tool_name: nil,
              tool_args: nil,
              call_id: nil,
              status: nil,
              timestamp: nil,
              agent_id: nil
  end

  defmodule ThreadView do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t() | nil,
            title: String.t() | nil,
            messages: [Message.t()],
            streaming: String.t(),
            loaded?: boolean(),
            scroll: :bottom | non_neg_integer(),
            status: :idle | :running | :error,
            turn_started_at: integer() | nil,
            cache_width: non_neg_integer() | nil,
            cache_lines: list(),
            cache_dirty?: boolean()
          }

    defstruct id: nil,
              title: nil,
              messages: [],
              streaming: "",
              loaded?: false,
              scroll: :bottom,
              status: :idle,
              turn_started_at: nil,
              cache_width: nil,
              cache_lines: [],
              cache_dirty?: true
  end

  defmodule AppModel do
    @moduledoc false

    @type t :: %__MODULE__{
            cwd: String.t(),
            threads: [ThreadView.t()],
            selected: non_neg_integer(),
            input: EchsCli.Tui.InputBuffer.t(),
            info: String.t(),
            window: map(),
            tick: non_neg_integer(),
            command_history: [String.t()],
            history_index: integer()
          }

    defstruct cwd: "",
              threads: [],
              selected: 0,
              input: nil,
              info: "Ready",
              window: %{width: 80, height: 24},
              tick: 0,
              command_history: [],
              history_index: -1
  end
end
