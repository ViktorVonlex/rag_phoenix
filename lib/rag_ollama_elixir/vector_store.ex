defmodule RagOllamaElixir.VectorStore do
  @moduledoc """
  PostgreSQL-based vector storage using pgvector extension.
  Provides efficient vector similarity search with persistent storage.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query
  require Logger

  alias RagOllamaElixir.Repo
  alias RagOllamaElixir.Conversations.DocumentChunk
  alias RagOllamaElixir.Retriever

  @doc """
  Store document chunks with their embeddings in the database.
  """
  def store_chunks(chunks_and_embeddings, conversation_id) when not is_nil(conversation_id) do
    Logger.info("Storing #{length(chunks_and_embeddings)} chunks for conversation #{conversation_id}")

    chunks_with_index = Enum.with_index(chunks_and_embeddings)

    # Insert chunks one by one to handle vector conversion properly
    results = Enum.map(chunks_with_index, fn {{content, embedding}, index} ->
      attrs = %{
        content: content,
        embedding: embedding,
        conversation_id: conversation_id,
        chunk_index: index,
        metadata: %{
          length: String.length(content),
          created_at: DateTime.utc_now()
        }
      }

      %DocumentChunk{}
      |> DocumentChunk.changeset(attrs)
      |> Repo.insert()
    end)

    # Check if all inserts were successful
    case Enum.split_with(results, fn result -> match?({:ok, _}, result) end) do
      {successes, []} ->
        Logger.info("Successfully stored #{length(successes)} chunks")
        {:ok, length(successes)}
      {successes, failures} ->
        Logger.error("Failed to store #{length(failures)} chunks, stored #{length(successes)}")
        {:error, "Partial failure: #{length(failures)} chunks failed"}
    end
  end

  @doc """
  Search for similar chunks using vector similarity.
  Returns chunks with their similarity scores.
  """
  def search(query_embedding, top_k \\ 5, conversation_id \\ nil) do
    Logger.info("Vector searching for top #{top_k} chunks in conversation #{conversation_id}")

    try do
      query_vector = Pgvector.new(query_embedding)

      query =
        from c in DocumentChunk,
          order_by: cosine_distance(c.embedding, ^query_vector),
          limit: ^top_k,
          select: %{
            content: c.content,
            distance: cosine_distance(c.embedding, ^query_vector),
            chunk_index: c.chunk_index,
            metadata: c.metadata
          }

      query = if conversation_id do
        where(query, [c], c.conversation_id == ^conversation_id)
      else
        query
      end

      results = Repo.all(query)

      # Convert to the format expected by the rest of the system: [{content, similarity}, ...]
      # Convert distance to similarity (1 - distance, since lower distance = higher similarity)
      formatted_results = Enum.map(results, fn %{content: content, distance: distance} ->
        similarity = 1.0 - distance
        {content, similarity}
      end)

      {:ok, formatted_results}
    rescue
      error ->
        Logger.error("Vector search failed: #{inspect(error)}")
        {:error, "Search failed: #{inspect(error)}"}
    end
  end

  @doc """
  Hybrid search combining vector similarity and lexical matching.
  Uses the Retriever module for sophisticated ranking.
  """
  def hybrid_search(query_text, query_embedding, top_k \\ 5, conversation_id \\ nil) do
    Logger.info("Hybrid searching for top #{top_k} chunks in conversation #{conversation_id}")

    try do
      # Get a larger set of candidates for hybrid processing
      candidate_limit = min(50, top_k * 10)
      query_vector = Pgvector.new(query_embedding)

      query =
        from c in DocumentChunk,
          order_by: cosine_distance(c.embedding, ^query_vector),
          limit: ^candidate_limit,
          select: %{
            content: c.content,
            embedding: c.embedding,
            distance: cosine_distance(c.embedding, ^query_vector),
            chunk_index: c.chunk_index
          }

      query = if conversation_id do
        where(query, [c], c.conversation_id == ^conversation_id)
      else
        query
      end

      candidates = Repo.all(query)

      # Convert to format expected by Retriever: [{content, embedding}, ...]
      vector_db_format = Enum.map(candidates, fn %{content: content, embedding: embedding} ->
        # Convert embedding back to list format for Retriever
        embedding_list = Pgvector.to_list(embedding)
        {content, embedding_list}
      end)

      # Use Retriever's hybrid search
      n_dense = min(20, top_k * 4)
      n_lexical = min(10, top_k * 2)

      hybrid_results = Retriever.hybrid_top_n_chunks(
        query_text,
        query_embedding,
        vector_db_format,
        n_dense,
        n_lexical,
        top_k
      )

      {:ok, hybrid_results}
    rescue
      error ->
        Logger.error("Hybrid search failed: #{inspect(error)}")
        {:error, "Search failed: #{inspect(error)}"}
    end
  end

  @doc """
  Clear all chunks for a specific conversation.
  """
  def clear_conversation(conversation_id) when not is_nil(conversation_id) do
    try do
      {count, _} = from(c in DocumentChunk, where: c.conversation_id == ^conversation_id)
                   |> Repo.delete_all()

      Logger.info("Cleared #{count} chunks for conversation #{conversation_id}")
      {:ok, count}
    rescue
      error ->
        Logger.error("Clear conversation failed: #{inspect(error)}")
        {:error, "Clear failed: #{inspect(error)}"}
    end
  end

  @doc """
  Clear all chunks (for testing purposes).
  """
  def clear_all do
    Repo.delete_all(DocumentChunk)
    Logger.info("Cleared all document chunks")
    :ok
  end

  @doc """
  Get statistics about stored vectors.
  """
  def stats(conversation_id \\ nil) do
    base_query = from c in DocumentChunk

    query = if conversation_id do
      where(base_query, [c], c.conversation_id == ^conversation_id)
    else
      base_query
    end

    count = Repo.aggregate(query, :count, :id)

    %{
      chunk_count: count,
      conversation_id: conversation_id
    }
  end

  @doc """
  Check if a conversation has stored vectors.
  """
  def has_vectors?(conversation_id) when not is_nil(conversation_id) do
    query = from c in DocumentChunk,
            where: c.conversation_id == ^conversation_id,
            limit: 1

    case Repo.one(query) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Get all chunks for a conversation (for debugging).
  """
  def get_chunks(conversation_id) when not is_nil(conversation_id) do
    try do
      query = from c in DocumentChunk,
              where: c.conversation_id == ^conversation_id,
              order_by: [asc: c.chunk_index],
              select: %{
                content: c.content,
                chunk_index: c.chunk_index,
                metadata: c.metadata
              }

      chunks = Repo.all(query)
      {:ok, chunks}
    rescue
      error ->
        Logger.error("Get chunks failed: #{inspect(error)}")
        {:error, "Get chunks failed: #{inspect(error)}"}
    end
  end
end
