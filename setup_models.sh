#!/usr/bin/env bash
set -e

# Check for Ollama installation
if ! command -v ollama &> /dev/null; then
    echo "Ollama not found. Please install Ollama first: https://ollama.com/download"
    exit 1
fi

# Download embedding model (bge-base-en-v1.5-gguf)
echo "Pulling embedding model (bge-base-en-v1.5-gguf)..."
ollama pull hf.co/CompendiumLabs/bge-base-en-v1.5-gguf

# Download language model (Llama-3.2-1B-Instruct-GGUF)
echo "Pulling language model (Llama-3.2-1B-Instruct-GGUF)..."
ollama pull hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF

echo "All models downloaded! 🦙"