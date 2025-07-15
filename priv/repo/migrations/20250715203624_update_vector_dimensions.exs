defmodule RagOllamaElixir.Repo.Migrations.UpdateVectorDimensions do
  use Ecto.Migration

  def up do
    # Drop the existing index first
    execute "DROP INDEX IF EXISTS document_chunks_embedding_idx"

    # Clear any existing data since we're changing dimensions
    execute "DELETE FROM document_chunks"

    # Drop and recreate the embedding column with correct dimensions
    alter table(:document_chunks) do
      remove :embedding
    end

    alter table(:document_chunks) do
      add :embedding, :vector, size: 768, null: false  # BGE-base-en-v1.5 uses 768 dimensions
    end

    # Recreate the vector similarity search index
    execute "CREATE INDEX document_chunks_embedding_idx ON document_chunks USING hnsw (embedding vector_cosine_ops)"
  end

  def down do
    # Drop the index first
    execute "DROP INDEX IF EXISTS document_chunks_embedding_idx"

    # Clear existing data
    execute "DELETE FROM document_chunks"

    # Revert to 1536 dimensions
    alter table(:document_chunks) do
      remove :embedding
    end

    alter table(:document_chunks) do
      add :embedding, :vector, size: 1536, null: false
    end

    # Recreate the index
    execute "CREATE INDEX document_chunks_embedding_idx ON document_chunks USING hnsw (embedding vector_cosine_ops)"
  end
end
