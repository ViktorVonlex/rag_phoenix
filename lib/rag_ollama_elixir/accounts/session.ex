defmodule RagOllamaElixir.Accounts.Session do
  @moduledoc """
  Session schema for user authentication.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sessions" do
    field :token, :string
    field :expires_at, :utc_datetime
    field :user_agent, :string
    field :ip_address, :string

    belongs_to :user, RagOllamaElixir.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:token, :expires_at, :user_agent, :ip_address, :user_id])
    |> validate_required([:token, :expires_at, :user_id])
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Creates a new session token for a user.
  """
  def create_changeset(user_id, attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = DateTime.utc_now() |> DateTime.add(30, :day)

    %__MODULE__{}
    |> cast(attrs, [:user_agent, :ip_address])
    |> put_change(:token, token)
    |> put_change(:expires_at, expires_at)
    |> put_change(:user_id, user_id)
    |> validate_required([:token, :expires_at, :user_id])
  end

  @doc """
  Checks if a session is expired.
  """
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
