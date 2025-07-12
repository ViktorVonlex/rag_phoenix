defmodule RagOllamaElixir.Chunkers.ChunkerBehaviour do
  @moduledoc """
  Behaviour defining the contract that all chunkers must implement.

  This ensures consistency across different chunking strategies and
  provides compile-time checking for implementation compliance.
  """

  @doc """
  Chunks the given text into a list of strings.

  ## Parameters
  - `text`: The input text to be chunked
  - `opts`: Optional parameters (e.g., client for semantic chunking)

  ## Returns
  - `{:ok, chunks}` where chunks is a list of strings
  - `{:error, reason}` if chunking fails
  """
  @callback chunk(text :: String.t(), opts :: keyword()) :: {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Returns metadata about the chunking strategy.

  ## Returns
  A map containing:
  - `:name` - Human readable name
  - `:description` - Brief description of the strategy
  - `:requires_client` - Boolean indicating if Ollama client is needed
  """
  @callback metadata() :: %{
    name: String.t(),
    description: String.t(),
    requires_client: boolean()
  }

  @doc """
  Validates if the given text is suitable for this chunking strategy.

  ## Parameters
  - `text`: The input text to validate

  ## Returns
  - `:ok` if text is suitable
  - `{:error, reason}` if text is not suitable
  """
  @callback validate_text(text :: String.t()) :: :ok | {:error, String.t()}

  @optional_callbacks validate_text: 1
end
