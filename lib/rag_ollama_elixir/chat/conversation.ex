defmodule RagOllamaElixir.Chat.Conversation do
  @moduledoc """
  Conversation schema for storing chat conversations.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    field :title, :string
    field :model_used, :string
    field :chunking_strategy, :string
    field :document_name, :string

    belongs_to :user, RagOllamaElixir.Accounts.User
    has_many :messages, RagOllamaElixir.Chat.Message

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :model_used, :chunking_strategy, :document_name, :user_id])
    |> validate_required([:title, :user_id])
    |> validate_inclusion(:chunking_strategy, ["basic", "semantic", "structured"])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Creates a new conversation with automatic title generation.
  """
  def create_changeset(user_id, attrs \\ %{}) do
    title = attrs[:title] || "Chat #{DateTime.utc_now() |> DateTime.to_date()}"

    %__MODULE__{}
    |> cast(attrs, [:model_used, :chunking_strategy, :document_name])
    |> put_change(:title, title)
    |> put_change(:user_id, user_id)
    |> validate_required([:title, :user_id])
    |> validate_inclusion(:chunking_strategy, ["basic", "semantic", "structured"])
  end
end
