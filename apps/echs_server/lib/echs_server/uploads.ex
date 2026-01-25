defmodule EchsServer.Uploads do
  @moduledoc false

  @spec prepare_image(Plug.Upload.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_image(%Plug.Upload{} = upload, opts \\ []) do
    inline? = Keyword.get(opts, :inline, false)

    with {:ok, meta} <-
           EchsCore.Uploads.store_file(upload.path,
             filename: upload.filename,
             content_type: upload.content_type
           ) do
      if inline? do
        with {:ok, image_url} <- EchsCore.Uploads.image_url(meta.upload_id) do
          {:ok,
           Map.merge(meta, %{
             image_url: image_url,
             content: %{"type" => "input_image", "image_url" => image_url}
           })}
        end
      else
        {:ok,
         Map.merge(meta, %{
           image_url: nil,
           content: %{"type" => "input_image", "upload_id" => meta.upload_id}
         })}
      end
    end
  end
end
