defmodule RagOllamaElixirWeb.ChunkingComparisonLive do
  use RagOllamaElixirWeb, :live_view

  alias RagOllamaElixir.PDFParser
  alias RagOllamaElixir.Chunkers.{BaseChunker, SemanticChunker, StructuredChunker}

  @uploads_dir "priv/static/uploads"

  def mount(_params, _session, socket) do
    File.mkdir_p!(@uploads_dir)

    socket =
      socket
      |> assign(:uploaded_file, nil)
      |> assign(:processing, false)
      |> assign(:chunks_comparison, %{})
      |> assign(:ollama_client, nil)
      |> allow_upload(:pdf,
          accept: ~w(.pdf),
          max_entries: 1,
          max_file_size: 50_000_000)

    client = Ollama.init()
    {:ok, assign(socket, :ollama_client, client)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    if socket.assigns.processing do
      {:noreply, socket}
    else
      uploaded_files =
        consume_uploaded_entries(socket, :pdf, fn %{path: path}, entry ->
          filename = entry.client_name
          temp_path = Path.join(@uploads_dir, "temp_#{System.unique_integer([:positive])}.pdf")
          File.cp!(path, temp_path)
          {:ok, {temp_path, filename}}
        end)

      if Enum.empty?(uploaded_files) do
        socket = put_flash(socket, :error, "No files were uploaded. Please select a PDF file first.")
        {:noreply, socket}
      else
        socket =
          socket
          |> assign(:processing, true)
          |> assign(:chunks_comparison, %{})

        # Process in background task
        live_view_pid = self()
        Task.start(fn ->
          send(live_view_pid, {:process_upload, uploaded_files})
        end)

        {:noreply, socket}
      end
    end
  end

  def handle_event("remove_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  def handle_info({:process_upload, uploaded_files}, socket) do
    case uploaded_files do
      [{temp_path, filename}] ->
        case compare_chunking_strategies(temp_path, socket.assigns.ollama_client) do
          {:ok, chunks_comparison} ->
            socket =
              socket
              |> assign(:chunks_comparison, chunks_comparison)
              |> assign(:uploaded_file, filename)
              |> assign(:processing, false)
              |> put_flash(:info, "Chunking comparison completed!")

            {:noreply, socket}

          {:error, reason} ->
            socket =
              socket
              |> assign(:processing, false)
              |> put_flash(:error, "Failed to process PDF: #{reason}")

            {:noreply, socket}
        end

      [] ->
        socket =
          socket
          |> assign(:processing, false)
          |> put_flash(:error, "No file uploaded")

        {:noreply, socket}

      _other ->
        socket =
          socket
          |> assign(:processing, false)
          |> put_flash(:error, "Unexpected file upload format")

        {:noreply, socket}
    end
  end

  defp compare_chunking_strategies(temp_path, client) do
    try do
      case PDFParser.extract_text(temp_path) do
        {:ok, text} ->
          {:ok, basic_chunks} = BaseChunker.chunk(text, [])

          semantic_chunks = case SemanticChunker.chunk(text, client: client) do
            {:ok, chunks} -> chunks
            {:error, _} -> ["Error: Semantic chunking failed"]
          end

          {:ok, structured_chunks} = StructuredChunker.chunk(text, [])

          comparison = %{
            basic: %{
              name: "Basic Chunking",
              description: "Simple text splitting on paragraphs and sentences",
              chunks: basic_chunks,
              count: length(basic_chunks),
              avg_length: avg_chunk_length(basic_chunks)
            },
            semantic: %{
              name: "Semantic Chunking",
              description: "Groups sentences by semantic similarity",
              chunks: semantic_chunks,
              count: length(semantic_chunks),
              avg_length: avg_chunk_length(semantic_chunks)
            },
            structured: %{
              name: "Structured Chunking",
              description: "Specialized for structured documents like transcripts, forms, invoices",
              chunks: structured_chunks,
              count: length(structured_chunks),
              avg_length: avg_chunk_length(structured_chunks)
            }
          }

          {:ok, comparison}

        {:error, reason} ->
          {:error, reason}
      end
    after
      # Clean up temp file
      File.rm(temp_path)
    end
  end

  defp avg_chunk_length(chunks) do
    if Enum.empty?(chunks) do
      0
    else
      total_length = chunks |> Enum.map(&String.length/1) |> Enum.sum()
      round(total_length / length(chunks))
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-purple-50 to-blue-100">
      <div class="container mx-auto px-4 py-8">
        <!-- Header -->
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-gray-800 mb-2">Chunking Strategy Comparison</h1>
          <p class="text-gray-600">Compare different text chunking strategies side by side</p>
          <div class="mt-4">
            <.link navigate="/rag" class="text-indigo-600 hover:text-indigo-800 underline">
              ← Back to RAG App
            </.link>
          </div>
        </div>

        <!-- Upload Section -->
        <div class="max-w-2xl mx-auto mb-8">
          <div class="bg-white rounded-lg shadow-lg p-6">
            <h2 class="text-xl font-semibold text-gray-800 mb-4">Upload Document for Analysis</h2>

            <form phx-submit="upload" phx-change="validate" class="space-y-4">
              <div class="border-2 border-dashed border-gray-300 rounded-lg p-6 text-center hover:border-purple-400 transition-colors">
                <.live_file_input upload={@uploads.pdf} class="hidden" />

                <%= if Enum.empty?(@uploads.pdf.entries) do %>
                  <div class="cursor-pointer" onclick={"document.querySelector('input[name=\"pdf\"]').click()"}>
                    <svg class="mx-auto h-12 w-12 text-gray-400" stroke="currentColor" fill="none" viewBox="0 0 48 48">
                      <path d="M28 8H12a4 4 0 00-4 4v20m32-12v8m0 0v8a4 4 0 01-4 4H12a4 4 0 01-4-4v-4m32-4l-3.172-3.172a4 4 0 00-5.656 0L28 28M8 32l9.172-9.172a4 4 0 015.656 0L28 28m0 0l4 4m4-24h8m-4-4v8m-12 4h.02" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
                    </svg>
                    <p class="mt-2 text-sm text-gray-600">
                      <span class="font-medium text-purple-600">Click to upload</span> or drag and drop
                    </p>
                    <p class="text-xs text-gray-500">PDF files only (max 50MB)</p>
                  </div>
                <% else %>
                  <%= for entry <- @uploads.pdf.entries do %>
                    <div class="flex items-center justify-between p-3 bg-gray-50 rounded">
                      <div class="flex items-center">
                        <svg class="h-8 w-8 text-red-600 mr-3" fill="currentColor" viewBox="0 0 20 20">
                          <path fill-rule="evenodd" d="M4 4a2 2 0 012-2h4.586A2 2 0 0112 2.586L15.414 6A2 2 0 0116 7.414V16a2 2 0 01-2 2H6a2 2 0 01-2-2V4z" clip-rule="evenodd" />
                        </svg>
                        <div>
                          <p class="text-sm font-medium text-gray-900"><%= entry.client_name %></p>
                          <p class="text-xs text-gray-500"><%= Float.round(entry.client_size / 1024 / 1024, 2) %> MB</p>
                        </div>
                      </div>
                      <button type="button" phx-click="remove_upload" phx-value-ref={entry.ref} class="text-red-500 hover:text-red-700">
                        <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
                          <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
                        </svg>
                      </button>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <%= if not Enum.empty?(@uploads.pdf.entries) and not @processing do %>
                <button type="submit" class="w-full bg-purple-600 text-white py-2 px-4 rounded-lg hover:bg-purple-700 transition-colors font-medium">
                  Analyze Chunking Strategies
                </button>
              <% end %>
            </form>

            <%= if @processing do %>
              <div class="mt-4 p-4 bg-blue-50 rounded-lg">
                <div class="flex items-center">
                  <svg class="animate-spin h-5 w-5 text-blue-600 mr-3" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  <span class="text-blue-800">Analyzing chunking strategies...</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Comparison Results -->
        <%= if @chunks_comparison != %{} do %>
          <div class="max-w-7xl mx-auto">
            <!-- Summary Stats -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
              <%= for {_strategy_key, strategy} <- @chunks_comparison do %>
                <div class="bg-white rounded-lg shadow-lg p-6">
                  <h3 class="text-xl font-semibold text-gray-800 mb-2"><%= strategy.name %></h3>
                  <p class="text-sm text-gray-600 mb-4"><%= strategy.description %></p>
                  <div class="grid grid-cols-2 gap-4">
                    <div class="text-center p-3 bg-gray-50 rounded">
                      <div class="text-2xl font-bold text-indigo-600"><%= strategy.count %></div>
                      <div class="text-sm text-gray-600">Chunks</div>
                    </div>
                    <div class="text-center p-3 bg-gray-50 rounded">
                      <div class="text-2xl font-bold text-purple-600"><%= strategy.avg_length %></div>
                      <div class="text-sm text-gray-600">Avg Length</div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <!-- Side-by-side Chunks -->
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <%= for {_strategy_key, strategy} <- @chunks_comparison do %>
                <div class="bg-white rounded-lg shadow-lg">
                  <div class="px-6 py-4 border-b bg-gray-50">
                    <h3 class="text-lg font-semibold text-gray-800"><%= strategy.name %></h3>
                  </div>
                  <div class="p-6 max-h-96 overflow-y-auto space-y-4">
                    <%= for {chunk, index} <- Enum.with_index(strategy.chunks) do %>
                      <div class="border rounded-lg p-4 hover:bg-gray-50 transition-colors overflow-hidden">
                        <div class="flex justify-between items-center mb-2">
                          <span class="text-xs font-medium text-gray-500">Chunk #<%= index + 1 %></span>
                          <span class="text-xs text-gray-400"><%= String.length(chunk) %> chars</span>
                        </div>
                        <p class="text-sm text-gray-700 leading-relaxed break-words overflow-wrap-anywhere"><%= chunk %></p>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
