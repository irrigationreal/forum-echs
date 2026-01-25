# EchsCli

Interactive CLI for running ECHS locally.

## Usage

From the umbrella root:

```bash
mix run -e 'EchsCli.main()'
```

Optional working directory:

```bash
mix run -e 'EchsCli.main(["/path/to/workdir"])'
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `echs_cli` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:echs_cli, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/echs_cli>.
