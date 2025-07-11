defmodule RagOllamaElixir.Conversations.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias RagOllamaElixir.Conversations.Conversation

  schema "messages" do
    field :content, :string
    field :role, :string
    field :metadata, :map

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:content, :role, :conversation_id, :metadata])
    |> validate_required([:content, :role, :conversation_id])
    |> validate_inclusion(:role, ["user", "assistant"])
    |> foreign_key_constraint(:conversation_id)
  end
end
