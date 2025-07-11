defmodule RagOllamaElixir.Conversations do
  @moduledoc """
  The Conversations context.
  """

  import Ecto.Query, warn: false
  alias RagOllamaElixir.Repo

  alias RagOllamaElixir.Conversations.Conversation
  alias RagOllamaElixir.Conversations.Message
  alias RagOllamaElixir.Accounts.User

  @doc """
  Returns the list of conversations for a user.

  ## Examples

      iex> list_conversations(user)
      [%Conversation{}, ...]

  """
  def list_conversations(%User{} = user) do
    Conversation
    |> where([c], c.user_id == ^user.id)
    |> order_by([c], desc: c.updated_at)
    |> preload(:messages)
    |> Repo.all()
  end

  @doc """
  Gets a single conversation.

  Raises `Ecto.NoResultsError` if the Conversation does not exist.

  ## Examples

      iex> get_conversation!(123)
      %Conversation{}

      iex> get_conversation!(456)
      ** (Ecto.NoResultsError)

  """
  def get_conversation!(id), do: Repo.get!(Conversation, id) |> Repo.preload(:messages)

  @doc """
  Gets a conversation belonging to a user.

  Returns `nil` if the conversation doesn't exist or doesn't belong to the user.
  """
  def get_user_conversation(user_id, conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id and c.user_id == ^user_id)
    |> preload(:messages)
    |> Repo.one()
  end

  @doc """
  Creates a conversation.

  ## Examples

      iex> create_conversation(%{field: value})
      {:ok, %Conversation{}}

      iex> create_conversation(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_conversation(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a conversation.

  ## Examples

      iex> update_conversation(conversation, %{field: new_value})
      {:ok, %Conversation{}}

      iex> update_conversation(conversation, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a conversation.

  ## Examples

      iex> delete_conversation(conversation)
      {:ok, %Conversation{}}

      iex> delete_conversation(conversation)
      {:error, %Ecto.Changeset{}}

  """
  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking conversation changes.

  ## Examples

      iex> change_conversation(conversation)
      %Ecto.Changeset{data: %Conversation{}}

  """
  def change_conversation(%Conversation{} = conversation, attrs \\ %{}) do
    Conversation.changeset(conversation, attrs)
  end

  @doc """
  Creates a message in a conversation.

  ## Examples

      iex> create_message(%{field: value})
      {:ok, %Message{}}

      iex> create_message(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_message(attrs \\ %{}) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Adds a message to a conversation and updates the conversation's updated_at timestamp.
  """
  def add_message_to_conversation(%Conversation{} = conversation, role, content, metadata \\ %{}) do
    Repo.transaction(fn ->
      # Create the message
      case create_message(%{
        conversation_id: conversation.id,
        role: role,
        content: content,
        metadata: metadata
      }) do
        {:ok, message} ->
          # Touch the conversation to update its updated_at timestamp
          conversation
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
          |> Repo.update!()

          message

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Gets messages for a conversation.
  """
  def get_conversation_messages(%Conversation{} = conversation) do
    Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates a new conversation with an initial user message.
  """
  def start_conversation(user_id, title, user_message, document_name \\ nil, chunking_strategy \\ nil) do
    Repo.transaction(fn ->
      # Create conversation
      case create_conversation(%{
        title: title,
        user_id: user_id,
        document_name: document_name,
        chunking_strategy: chunking_strategy
      }) do
        {:ok, conversation} ->
          # Add the initial user message
          case add_message_to_conversation(conversation, "user", user_message) do
            {:ok, _message} ->
              conversation |> Repo.preload(:messages)
            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end
end
