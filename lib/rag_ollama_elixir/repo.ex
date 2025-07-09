defmodule RagOllamaElixir.Repo do
  use Ecto.Repo,
    otp_app: :rag_ollama_elixir,
    adapter: Ecto.Adapters.Postgres
end
