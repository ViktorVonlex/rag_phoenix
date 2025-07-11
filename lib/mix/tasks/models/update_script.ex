defmodule Mix.Tasks.Models.UpdateScript do
  @moduledoc """
  Updates the setup_models.sh script with current model configuration.

  ## Usage

      mix models.update_script

  This ensures the setup script stays in sync with the Models configuration.
  """

  use Mix.Task

  @shortdoc "Updates setup_models.sh with current model configuration"

  def run(_args) do
    script_content = generate_script_content()

    File.write!("setup_models.sh", script_content)
    File.chmod!("setup_models.sh", 0o755)  # Make executable

    Mix.shell().info("Updated setup_models.sh with current model configuration")
    Mix.shell().info("Models: #{inspect(RagOllamaElixir.Models.all_models())}")
  end

  defp generate_script_content do
    """
    #!/usr/bin/env bash
    set -e

    # This script is generated from RagOllamaElixir.Models configuration
    # To update model versions, edit lib/rag_ollama_elixir/models.ex
    # Then run: mix models.update_script

    # Check for Ollama installation
    if ! command -v ollama &> /dev/null; then
        echo "Ollama not found. Please install Ollama first: https://ollama.com/download"
        exit 1
    fi

    #{RagOllamaElixir.Models.setup_script_content()}
    echo "All models downloaded! 🦙"
    """
  end
end
