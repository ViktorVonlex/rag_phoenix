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

# Download embedding model
echo "Pulling embedding model (hf.co/CompendiumLabs/bge-base-en-v1.5-gguf)..."
ollama pull hf.co/CompendiumLabs/bge-base-en-v1.5-gguf

# Download language model  
echo "Pulling language model (hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF)..."
ollama pull hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF

echo "All models downloaded! 🦙"
