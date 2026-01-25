# EchsCodex

Codex API client for ECHS. Handles auth loading, token refresh, and SSE
streaming against the responses endpoints.

## Auth

This client reads tokens from `~/.codex/auth.json`. Run `codex login` to
initialize or refresh the file.

## Usage

```elixir
{:ok, _} = Application.ensure_all_started(:echs_codex)

EchsCodex.stream_response(
  model: "gpt-5.2-codex",
  instructions: "Be concise",
  input: [],
  tools: [],
  reasoning: "medium",
  on_event: fn event -> IO.inspect(event) end
)
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `echs_codex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:echs_codex, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/echs_codex>.
