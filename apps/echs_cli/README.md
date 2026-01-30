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

## TUI

Ratatouille-powered terminal UI:

```bash
mix run -e 'EchsCli.Tui.main()'
```

Optional working directory:

```bash
mix run -e 'EchsCli.Tui.main(["/path/to/workdir"])'
```

Shortcut script from the umbrella root:

```bash
./bin/echs-tui
./bin/echs-tui /path/to/workdir
```

## Installation

This package is not published to Hex yet. If you vendor it yourself, add
`echs_cli` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:echs_cli, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc).
