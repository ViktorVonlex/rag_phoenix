defmodule RagOllamaElixir.Models do
  @moduledoc """
  Centralized model configuration for the RAG system.
  This ensures consistency between setup scripts and application code.
  """

  @embedding_model "hf.co/CompendiumLabs/bge-base-en-v1.5-gguf"
  @chat_model "hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF"

  def embedding_model, do: @embedding_model
  def chat_model, do: @chat_model

  def all_models, do: [@embedding_model, @chat_model]

  @doc """
  Generates a shell script snippet for downloading all models.
  This can be used to keep setup scripts in sync.
  """
  def setup_script_content do
    """
    # Download embedding model
    echo "Pulling embedding model (#{@embedding_model})..."
    ollama pull #{@embedding_model}

    # Download language model
    echo "Pulling language model (#{@chat_model})..."
    ollama pull #{@chat_model}
    """
  end
end
