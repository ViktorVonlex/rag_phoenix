defmodule RagOllamaElixir.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :title, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :document_name, :string
      add :chunking_strategy, :string
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:user_id])
    create index(:conversations, [:user_id, :inserted_at])

    create table(:messages) do
      add :content, :text, null: false
      add :role, :string, null: false  # "user" or "assistant"
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :metadata, :map  # can store embedding vectors, sources, etc.

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:conversation_id])
    create index(:messages, [:conversation_id, :inserted_at])
  end
end
