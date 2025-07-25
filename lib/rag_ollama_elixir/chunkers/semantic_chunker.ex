defmodule RagOllamaElixir.Chunkers.SemanticChunker do
  @moduledoc """
  Semantic chunker for PDF or long text.
  - Splits text into sentences.
  - Embeds each sentence.
  - Computes cosine similarity between adjacent sentences.
  - Starts a new chunk when semantic similarity drops below a threshold.
  - Optionally merges small chunks up to a target size.
  """

  @behaviour RagOllamaElixir.Chunkers.ChunkerBehaviour

  @default_threshold 0.65  # Lowered from 0.7 to be more permissive
  @default_min_chunk_size 250

  # Public entry point
  @impl true
  def chunk(text, opts \\ []) do
    client = Keyword.get(opts, :client)

    if is_nil(client) do
      {:error, "Semantic chunking requires :client option"}
    else
      do_chunk(text, client, opts)
    end
  end

  @impl true
  def metadata do
    %{
      name: "Semantic Chunking",
      description: "Groups similar sentences together using AI embeddings",
      requires_client: true
    }
  end

  @impl true
  def validate_text(text) when is_binary(text) and byte_size(text) > 0, do: :ok
  def validate_text(_), do: {:error, "Text must be a non-empty string"}

  # Internal implementation
  defp do_chunk(text, client, opts) do
    try do
      threshold = Keyword.get(opts, :threshold, @default_threshold)
      min_chunk_size = Keyword.get(opts, :min_chunk_size, @default_min_chunk_size)

      # 1. Split to sentences (handles . ! ? and also \n)
      # Apply whitespace normalization to help with tabular data
      normalized_text = text
      |> String.split("\n")
      |> Enum.map(&String.replace(&1, ~r/\s+/, " "))  # Normalize whitespace
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))
      |> Enum.join("\n")

      sentences =
        normalized_text
        |> String.split(~r/(?<=[.?!])\s+|\n+/)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      # Handle edge case: if only one sentence, return it
      if length(sentences) <= 1 do
        {:ok, sentences}
      else
        # 2. Embed all sentences
        case RagOllamaElixir.Embedder.embed(client, sentences) do
          {:ok, sentence_embeddings} ->
            # 3. Semantic chunking
            semantic_chunks =
              do_semantic_chunking(sentences, sentence_embeddings, threshold)

            # 4. Merge small chunks (optional)
            final_chunks = merge_small_chunks(semantic_chunks, min_chunk_size)
            {:ok, final_chunks}

          {:error, _reason} ->
            # Fallback to simple chunking if embedding fails
            fallback_chunks = fallback_chunking(text, min_chunk_size)
            {:ok, fallback_chunks}
        end
      end
    rescue
      error ->
        {:error, "Semantic chunking failed: #{inspect(error)}"}
    end
  end

  defp do_semantic_chunking(sentences, embeddings, threshold) do
    {chunks, current_chunk} =
      Enum.reduce(1..(length(sentences) - 1), {[], [hd(sentences)]}, fn i, {chunks, curr} ->
        prev_emb = Enum.at(embeddings, i - 1)
        curr_emb = Enum.at(embeddings, i)
        sim = RagOllamaElixir.Retriever.cosine_similarity(prev_emb, curr_emb)
        sentence = Enum.at(sentences, i)

        if sim < threshold do
          {[Enum.join(curr, " ") | chunks], [sentence]}
        else
          {chunks, curr ++ [sentence]}
        end
      end)

    Enum.reverse([Enum.join(current_chunk, " ") | chunks])
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp merge_small_chunks(chunks, min_size) do
    Enum.reduce(chunks, {[], ""}, fn chunk, {acc, current} ->
      chunk = String.trim(chunk)
      cond do
        current == "" -> {acc, chunk}
        byte_size(current) + byte_size(chunk) + 1 < min_size ->
          {acc, current <> " " <> chunk}
        true ->
          {[current | acc], chunk}
      end
    end)
    |> (fn {acc, last} -> Enum.reverse([last | acc]) |> Enum.filter(&(&1 != "")) end).()
  end

  # Fallback to simple chunking if semantic chunking fails
  defp fallback_chunking(text, min_size) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.flat_map(&split_section/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> merge_small_chunks(min_size)
  end

  defp split_section(section) when byte_size(section) < @default_min_chunk_size, do: [section]
  defp split_section(section) do
    String.split(section, ~r/\n|(?<=[.?!])\s+/)
  end
end
