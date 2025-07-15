defmodule RagOllamaElixir.Repo.Migrations.CreateDocumentChunks do
  use Ecto.Migration

  def up do
    # Enable pgvector extension if not already enabled
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:document_chunks) do
      add :content, :text, null: false
      add :embedding, :vector, size: 1536, null: false  # Assuming OpenAI/Ollama embeddings are 1536 dimensions
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :chunk_index, :integer, null: false  # Order within the document
      add :metadata, :map  # Additional metadata like page numbers, etc.

      timestamps(type: :utc_datetime)
    end

    create index(:document_chunks, [:conversation_id])
    create index(:document_chunks, [:conversation_id, :chunk_index])

    # Create vector similarity search index using HNSW algorithm
    # This dramatically speeds up similarity searches
    execute "CREATE INDEX document_chunks_embedding_idx ON document_chunks USING hnsw (embedding vector_cosine_ops)"
  end

  def down do
    drop table(:document_chunks)
  end
end
