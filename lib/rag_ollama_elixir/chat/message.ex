defmodule RagOllamaElixir.Chat.Message do
  @moduledoc """
  Message schema for storing individual chat messages.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :content, :string
    field :role, :string  # "user" or "assistant"
    field :metadata, :map  # For storing additional context like retrieved chunks

    belongs_to :conversation, RagOllamaElixir.Chat.Conversation

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:content, :role, :metadata, :conversation_id])
    |> validate_required([:content, :role, :conversation_id])
    |> validate_inclusion(:role, ["user", "assistant"])
    |> foreign_key_constraint(:conversation_id)
  end

  @doc """
  Creates a user message.
  """
  def user_changeset(conversation_id, content, metadata \\ %{}) do
    %__MODULE__{}
    |> cast(%{content: content, metadata: metadata}, [:content, :metadata])
    |> put_change(:role, "user")
    |> put_change(:conversation_id, conversation_id)
    |> validate_required([:content, :role, :conversation_id])
  end

  @doc """
  Creates an assistant message.
  """
  def assistant_changeset(conversation_id, content, metadata \\ %{}) do
    %__MODULE__{}
    |> cast(%{content: content, metadata: metadata}, [:content, :metadata])
    |> put_change(:role, "assistant")
    |> put_change(:conversation_id, conversation_id)
    |> validate_required([:content, :role, :conversation_id])
  end
end
