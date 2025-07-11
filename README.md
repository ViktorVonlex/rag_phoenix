# RagOllamaElixir

A Phoenix LiveView application for Retrieval-Augmented Generation (RAG) using Ollama for embeddings and chat functionality. Upload PDFs, chunk them using different strategies, and ask questions about your documents.

## Features

- 📄 PDF upload and processing
- 🔄 Multiple chunking strategies (basic, semantic, structured)
- 🤖 Chat with your documents using Ollama models
- 🔍 Semantic search with embeddings
- 📊 Chunking strategy comparison and diagnostics
- 💬 Streaming chat responses
- 🔐 User authentication and session management
- 💾 Persistent vector database for embeddings

## Prerequisites

- Elixir 1.14+
- Phoenix Framework
- Docker and Docker Compose (for PostgreSQL)
- Ollama installed and running

## Setup

### 1. Install Dependencies

```bash
mix deps.get
```

### 2. Set up PostgreSQL Database

Start the PostgreSQL container:

```bash
docker-compose up -d postgres
```

### 3. Set up Ollama Models

Install and start the required models:

```bash
# Make the setup script executable and run it
chmod +x setup_models.sh
./setup_models.sh
```

### 4. Configure and Start the Application

```bash
# Create and migrate the database
mix ecto.setup

# Install and build assets
mix assets.setup
mix assets.build

# Start the Phoenix server
mix phx.server
```

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Development

### Database Management

```bash
# Start PostgreSQL
docker-compose up -d postgres

# Reset database
mix ecto.reset

# Create a new migration
mix ecto.gen.migration migration_name

# Run migrations
mix ecto.migrate
```

### Optional: PostgreSQL with Vector Extension

For future vector storage capabilities, you can also run PostgreSQL with the pgvector extension:

```bash
# Start PostgreSQL with vector extension
docker-compose --profile vector up -d postgres_vector
```

### Running Tests

```bash
mix test
```

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
