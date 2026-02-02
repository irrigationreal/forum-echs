# EchsCodex

Codex API client for ECHS. Handles auth loading, token refresh, and SSE
streaming against the responses endpoints.

## Auth

By default, this client reads tokens from `~/.codex/auth.json`. Run `codex login`
to initialize or refresh the file.

Overrides:

- `ECHS_CODEX_AUTH_PATH` - custom path to the auth JSON file
- `ECHS_CODEX_ACCESS_TOKEN` - direct access token (bypasses `~/.codex/auth.json`)
- `ECHS_CODEX_ACCOUNT_ID` - required when `ECHS_CODEX_ACCESS_TOKEN` is set
- `ECHS_CODEX_BASE_URL` - override responses endpoint base URL
- `ECHS_CODEX_COMPACT_URL` - override compact endpoint URL

Note: if you use `ECHS_CODEX_ACCESS_TOKEN`, token refresh via `codex login status`
is disabled.

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

This package is not published to Hex yet. If you vendor it yourself, add
`echs_codex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:echs_codex, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc).
