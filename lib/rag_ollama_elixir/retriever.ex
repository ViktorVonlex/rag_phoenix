defmodule RagOllamaElixir.Retriever do
  @moduledoc "Retrieves top-N relevant chunks by cosine similarity"

  def cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    norm_a = :math.sqrt(Enum.map(a, & &1 * &1) |> Enum.sum())
    norm_b = :math.sqrt(Enum.map(b, & &1 * &1) |> Enum.sum())
    if norm_a == 0 or norm_b == 0, do: 0.0, else: dot / (norm_a * norm_b)
  end

  def top_n_chunks(query_embedding, vector_db, n) do
    vector_db
    |> Enum.map(fn {chunk, emb} -> {chunk, cosine_similarity(query_embedding, emb)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(n)
  end

  def lexical_overlap(query, chunk) do
    query_words = MapSet.new(String.downcase(query) |> String.split(~r/\W+/))
    chunk_words = MapSet.new(String.downcase(chunk) |> String.split(~r/\W+/))
    MapSet.size(MapSet.intersection(query_words, chunk_words))
  end

  def top_n_chunks_lexical(query, vector_db, n) do
    vector_db
    |> Enum.map(fn {chunk, _emb} -> {chunk, lexical_overlap(query, chunk)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(n)
  end

  def hybrid_top_n_chunks(query, query_embedding, vector_db, n_dense, n_lexical, n_final) do
    dense = top_n_chunks(query_embedding, vector_db, n_dense)
    lexical = top_n_chunks_lexical(query, vector_db, n_lexical)
    all = dense ++ lexical

    # Remove duplicates, keep highest score for each chunk
    all
    |> Enum.group_by(fn {chunk, _score} -> chunk end)
    |> Enum.map(fn {chunk, pairs} ->
      # Take highest score from either method (or you could sum, or use other logic)
      max_score = pairs |> Enum.map(&elem(&1, 1)) |> Enum.max()
      {chunk, max_score}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(n_final)
  end
end
