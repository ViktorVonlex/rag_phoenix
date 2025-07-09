defmodule RagOllamaElixir.Embedder do
  @moduledoc "Handles embedding text with Ollama"

  @embedding_model "hf.co/CompendiumLabs/bge-base-en-v1.5-gguf"

  def embed(client, texts) when is_list(texts) do
    params = [model: @embedding_model, input: texts]

    case Ollama.embed(client, params) do
      {:ok, response} ->
        case response do
          %{"embedding" => embeddings} -> {:ok, embeddings}
          %{"embeddings" => embeddings} -> {:ok, embeddings}
          other ->
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
