defmodule RagOllamaElixir.Conversations.DocumentChunk do
  @moduledoc """
  Schema for document chunks with vector embeddings stored in pgvector.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias RagOllamaElixir.Conversations.Conversation

  schema "document_chunks" do
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :chunk_index, :integer
    field :metadata, :map

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(document_chunk, attrs) do
    document_chunk
    |> cast(attrs, [:content, :embedding, :conversation_id, :chunk_index, :metadata])
    |> validate_required([:content, :embedding, :conversation_id, :chunk_index])
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :chunk_index], name: :document_chunks_conversation_id_chunk_index_index)
  end
end
