defmodule RagOllamaElixir.VectorDB do
  @moduledoc """
  A lightweight vector database with file persistence.
  Stores embeddings in memory for fast access with periodic saves to disk.
  """

  use GenServer
  require Logger

  @db_file "priv/vector_db.etf"
  @save_interval 30_000  # Save every 30 seconds

  defstruct vectors: %{}, metadata: %{}, next_id: 1

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_documents(chunks_and_embeddings, conversation_id \\ nil) do
    GenServer.call(__MODULE__, {:add_documents, chunks_and_embeddings, conversation_id})
  end

  def store(text, embedding, conversation_id \\ nil) do
    add_documents([{text, embedding}], conversation_id)
  end

  def search(query_embedding, top_k \\ 5, conversation_id \\ nil) do
    GenServer.call(__MODULE__, {:search, query_embedding, top_k, conversation_id})
  end

  def clear(conversation_id \\ nil) do
    GenServer.call(__MODULE__, {:clear, conversation_id})
  end

  def load_conversation(conversation_id) do
    GenServer.call(__MODULE__, {:load_conversation, conversation_id})
  end

  def stats() do
    GenServer.call(__MODULE__, :stats)
  end

  def save() do
    GenServer.call(__MODULE__, :save)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    File.mkdir_p!(Path.dirname(@db_file))

    state = case File.read(@db_file) do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary)
        rescue
          _ -> %__MODULE__{}
        end
      {:error, _} ->
        %__MODULE__{}
    end

    # Schedule periodic saves
    Process.send_after(self(), :save, @save_interval)

    Logger.info("VectorDB started with #{map_size(state.vectors)} documents")
    {:ok, state}
  end

  @impl true
  def handle_call({:add_documents, chunks_and_embeddings, conversation_id}, _from, state) do
    {new_state, ids} = Enum.reduce(chunks_and_embeddings, {state, []}, fn {chunk, embedding}, {acc_state, acc_ids} ->
      id = acc_state.next_id
      new_vectors = Map.put(acc_state.vectors, id, embedding)
      new_metadata = Map.put(acc_state.metadata, id, %{
        chunk: chunk,
        timestamp: DateTime.utc_now(),
        length: String.length(chunk),
        conversation_id: conversation_id
      })

      new_state = %{acc_state |
        vectors: new_vectors,
        metadata: new_metadata,
        next_id: id + 1
      }

      {new_state, [id | acc_ids]}
    end)

    {:reply, {:ok, Enum.reverse(ids)}, new_state}
  end

  @impl true
  def handle_call({:search, query_embedding, top_k, conversation_id}, _from, state) do
    # Filter by conversation_id if provided
    vectors_to_search = case conversation_id do
      nil -> state.vectors
      conv_id ->
        state.vectors
        |> Enum.filter(fn {id, _embedding} ->
          metadata = Map.get(state.metadata, id)
          metadata && Map.get(metadata, :conversation_id) == conv_id
        end)
        |> Map.new()
    end

    results = vectors_to_search
    |> Enum.map(fn {id, embedding} ->
      similarity = cosine_similarity(query_embedding, embedding)
      metadata = Map.get(state.metadata, id)
      {id, similarity, metadata.chunk}
    end)
    |> Enum.sort_by(fn {_id, similarity, _chunk} -> similarity end, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn {_id, similarity, chunk} -> {chunk, similarity} end)

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:clear, conversation_id}, _from, state) when conversation_id != nil do
    # Clear only vectors for a specific conversation
    filtered_vectors = state.vectors
    |> Enum.reject(fn {id, _embedding} ->
      metadata = Map.get(state.metadata, id)
      metadata && Map.get(metadata, :conversation_id) == conversation_id
    end)
    |> Map.new()

    filtered_metadata = state.metadata
    |> Enum.reject(fn {_id, metadata} ->
      metadata && Map.get(metadata, :conversation_id) == conversation_id
    end)
    |> Map.new()

    new_state = %{state | vectors: filtered_vectors, metadata: filtered_metadata}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:clear, nil}, _from, _state) do
    # Clear all vectors
    new_state = %__MODULE__{}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:load_conversation, conversation_id}, _from, state) do
    # Check if conversation has any vectors
    has_vectors = state.metadata
    |> Enum.any?(fn {_id, metadata} ->
      metadata && Map.get(metadata, :conversation_id) == conversation_id
    end)

    {:reply, {:ok, has_vectors}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    new_state = %__MODULE__{}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      document_count: map_size(state.vectors),
      next_id: state.next_id,
      memory_usage: :erlang.system_info(:process_heap_size)
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:save, _from, state) do
    case save_to_disk(state) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:save, state) do
    save_to_disk(state)
    Process.send_after(self(), :save, @save_interval)
    {:noreply, state}
  end

  # Private functions

  defp save_to_disk(state) do
    try do
      binary = :erlang.term_to_binary(state)
      File.write(@db_file, binary)
    rescue
      error ->
        Logger.error("Failed to save VectorDB: #{inspect(error)}")
        {:error, error}
    end
  end

  defp cosine_similarity(vec1, vec2) when is_list(vec1) and is_list(vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(vec1, 0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(vec2, 0, fn x, acc -> acc + x * x end))

    if norm1 == 0 or norm2 == 0 do
      0.0
    else
      dot_product / (norm1 * norm2)
    end
  end
end
