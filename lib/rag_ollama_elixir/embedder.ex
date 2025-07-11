defmodule RagOllamaElixir.Embedder do
  @moduledoc "Handles embedding text with Ollama"

  alias RagOllamaElixir.Models

  def embed(client, texts) when is_list(texts) do
    params = [model: Models.embedding_model(), input: texts]

    case Ollama.embed(client, params) do
      {:ok, response} ->
        IO.puts("=== Ollama embed response structure ===")
        IO.inspect(Map.keys(response), label: "Response keys")
        case response do
          %{"embedding" => embeddings} -> {:ok, embeddings}
          %{"embeddings" => embeddings} -> {:ok, embeddings}
          other ->
            IO.inspect(other, label: "Unexpected response format")
            {:error, "Unexpected response format: #{inspect(other)}"}
        end
      error -> error
    end
  end

  def embed(client, text) when is_binary(text) do
    embed(client, [text])
    |> case do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end
end
