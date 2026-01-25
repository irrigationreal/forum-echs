defmodule Mix.Tasks.Echs.Openapi do
  use Mix.Task

  @shortdoc "Write the ECHS OpenAPI spec to a JSON file"

  @moduledoc """
  Usage:

      mix echs.openapi
      mix echs.openapi --out openapi.json
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [out: :string])
    out_path = Keyword.get(opts, :out, "openapi.json")

    spec = EchsProtocol.V1.OpenAPI.spec()
    json = Jason.encode_to_iodata!(spec, pretty: true)

    File.write!(out_path, [json, "\n"])
    Mix.shell().info("Wrote #{out_path}")
  end
end
