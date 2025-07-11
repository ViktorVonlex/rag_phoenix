defmodule RagOllamaElixir.Chat do
  @moduledoc """
  Handles assembling context and interacting with Ollama LLM for chat.
  """

  alias RagOllamaElixir.Models

  # Builds the prompt and calls Ollama chat
  def ask(client, context_chunks, user_query, opts \\ []) do
    context =
      context_chunks
      |> Enum.map_join("\n", fn {chunk, _sim} -> chunk end)

    prompt = """
    You are a helpful chatbot.
    Use only the following pieces of context to answer the question. Don't make up any new information:
    #{context}
    """

    messages = [
      %{role: "system", content: prompt},
      %{role: "user", content: user_query}
    ]

    params =
      [
        model: Models.chat_model(),
        messages: messages
      ]
      |> Keyword.merge(opts)

    Ollama.chat(client, params)
  end

  # Streaming support - pass the PID to stream to
  def ask_stream(client, context_chunks, user_query, stream_pid, opts \\ []) do
    ask(client, context_chunks, user_query, Keyword.put(opts, :stream, stream_pid))
  end
end
