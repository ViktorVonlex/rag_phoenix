defmodule RagOllamaElixir.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias RagOllamaElixir.Accounts.User
  alias RagOllamaElixir.Conversations.Message

  schema "conversations" do
    field :title, :string
    field :document_name, :string
    field :chunking_strategy, :string
    field :metadata, :map

    belongs_to :user, User
    has_many :messages, Message, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :user_id, :document_name, :chunking_strategy, :metadata])
    |> validate_required([:title, :user_id])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:chunking_strategy, ["basic", "semantic", "structured"])
    |> foreign_key_constraint(:user_id)
  end
end
