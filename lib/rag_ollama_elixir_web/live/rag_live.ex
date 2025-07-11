defmodule RagOllamaElixirWeb.RagLive do
  use RagOllamaElixirWeb, :live_view

  alias RagOllamaElixir.{PDFParser, Chunker, SemanticChunker, Embedder, Chat, VectorDB}
  alias RagOllamaElixir.StructuredChunker

  @uploads_dir "priv/static/uploads"

  def mount(_params, _session, socket) do
    File.mkdir_p!(@uploads_dir)

    socket =
      socket
      |> assign(:messages, [])
      |> assign(:current_question, "")
      |> assign(:vector_db, [])
      |> assign(:processing, false)
      |> assign(:ollama_client, nil)
      |> assign(:uploaded_file, nil)
      |> assign(:chunking_strategy, :semantic)  # :semantic or :basic
      |> assign(:streaming_message, nil)  # For streaming responses
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
          |> assign(:messages, [])
          |> assign(:vector_db, [])

        # Process upload
        IO.puts("=== Starting background task for file processing ===")
        live_view_pid = self()
        Task.start(fn ->
          IO.puts("=== Background task started, sending message ===")
          send(live_view_pid, {:process_upload, uploaded_files})
        end)

        {:noreply, socket}
      end
    end
  end

  def handle_event("ask_question", %{"question" => question}, socket) do
    # Check if we have documents stored in the VectorDB
    has_documents = socket.assigns.vector_db != [] or 
                   (VectorDB.stats() |> Map.get(:document_count, 0)) > 0
    
    if question != "" and not socket.assigns.processing and has_documents do
      socket = assign(socket, :processing, true)

      # Add user message
      user_message = %{role: :user, content: question, timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [user_message]

      # Start streaming assistant message
      assistant_message = %{role: :assistant, content: "", timestamp: DateTime.utc_now(), streaming: true}
      messages = messages ++ [assistant_message]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming_message, assistant_message)

      live_view_pid = self()
      Task.start(fn ->
        send(live_view_pid, {:process_question_stream, question})
      end)

      {:noreply, assign(socket, :current_question, "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_question", %{"question" => question}, socket) do
    {:noreply, assign(socket, :current_question, question)}
  end

  def handle_event("remove_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  def handle_event("toggle_chunking", _params, socket) do
    new_strategy =
      case socket.assigns.chunking_strategy do
        :semantic -> :basic
        :basic -> :structured
        :structured -> :semantic
      end
    {:noreply, assign(socket, :chunking_strategy, new_strategy)}
  end

  def handle_info({:process_upload, uploaded_files}, socket) do
    IO.puts("=== HANDLE_INFO: Processing upload started ===")
    IO.inspect(uploaded_files, label: "Uploaded files")

    case uploaded_files do
      [{temp_path, filename}] ->
        IO.puts("Processing file: #{filename} at #{temp_path}")
        case process_pdf_file(temp_path, socket.assigns.ollama_client, socket.assigns.chunking_strategy) do
          {:ok, document_count} ->
            IO.puts("=== PDF processed successfully! Created #{document_count} chunks ===")
            socket =
              socket
              |> assign(:vector_db, :persistent)  # Flag that we have documents
              |> assign(:uploaded_file, filename)
              |> assign(:processing, false)
              |> put_flash(:info, "PDF processed successfully! You can now ask questions.")

            # Auto-clear flash message after 3 seconds with fade out
            Process.send_after(self(), :start_flash_fade, 3000)
            Process.send_after(self(), :clear_flash, 3500)

            {:noreply, socket}

          {:error, reason} ->
            IO.puts("=== PDF processing failed: #{inspect(reason)} ===")
            socket =
              socket
              |> assign(:processing, false)
              |> put_flash(:error, "Failed to process PDF: #{reason}")

            {:noreply, socket}
        end

      [] ->
        IO.puts("=== No files in uploaded_files list ===")
        socket =
          socket
          |> assign(:processing, false)
          |> put_flash(:error, "No file uploaded")

        {:noreply, socket}

      _other ->
        IO.puts("=== Unexpected uploaded_files format ===")
        socket =
          socket
          |> assign(:processing, false)
          |> put_flash(:error, "Unexpected file upload format")

        {:noreply, socket}
    end
  end

  def handle_info({:process_question_stream, question}, socket) do
    IO.puts("=== HANDLE_INFO: Processing question stream: #{question} ===")
    case answer_question_stream(question, socket.assigns.vector_db, socket.assigns.ollama_client, self()) do
      {:ok, :started} ->
        # Streaming started successfully, messages will come via handle_info
        {:noreply, socket}
      {:error, reason} ->
        IO.puts("=== Question processing failed: #{inspect(reason)} ===")
        socket =
          socket
          |> assign(:processing, false)
          |> assign(:streaming_message, nil)
          |> put_flash(:error, "Failed to get answer: #{reason}")

        {:noreply, socket}
    end
  end

  def handle_info({:stream_chunk, chunk}, socket) do
    # Update the streaming message with new content
    if socket.assigns.streaming_message do
      updated_content = socket.assigns.streaming_message.content <> chunk
      updated_message = %{socket.assigns.streaming_message | content: updated_content}

      # Update the last message in the messages list
      messages = List.update_at(socket.assigns.messages, -1, fn _ -> updated_message end)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming_message, updated_message)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_complete}, socket) do
    # Streaming is complete
    if socket.assigns.streaming_message do
      # Mark the message as no longer streaming
      final_message = Map.delete(socket.assigns.streaming_message, :streaming)
      messages = List.update_at(socket.assigns.messages, -1, fn _ -> final_message end)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming_message, nil)
        |> assign(:processing, false)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :processing, false)}
    end
  end

  def handle_info({:stream_error, reason}, socket) do
    IO.puts("=== Stream error: #{inspect(reason)} ===")
    socket =
      socket
      |> assign(:processing, false)
      |> assign(:streaming_message, nil)
      |> put_flash(:error, "Streaming failed: #{reason}")

    {:noreply, socket}
  end

  def handle_info({:process_question, question}, socket) do
    IO.puts("=== HANDLE_INFO: Processing question: #{question} ===")
    case answer_question(question, socket.assigns.vector_db, socket.assigns.ollama_client) do
      {:ok, answer} ->
        IO.puts("=== Question answered successfully ===")
        assistant_message = %{role: :assistant, content: answer, timestamp: DateTime.utc_now()}
        messages = socket.assigns.messages ++ [assistant_message]

        socket =
          socket
          |> assign(:messages, messages)
          |> assign(:processing, false)

        {:noreply, socket}

      {:error, reason} ->
        IO.puts("=== Question processing failed: #{inspect(reason)} ===")
        socket =
          socket
          |> assign(:processing, false)
          |> put_flash(:error, "Failed to get answer: #{reason}")

        {:noreply, socket}
    end
  end

  def handle_info(:start_flash_fade, socket) do
    {:noreply, push_event(socket, "fade-flash", %{})}
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  defp process_pdf_file(temp_path, client, chunking_strategy) do
    try do
      # Clear previous documents
      VectorDB.clear()
      
      # Process the PDF
      case PDFParser.extract_text(temp_path) do
        {:ok, text} ->
          chunks = case chunking_strategy do
            :semantic ->
              IO.puts("=== Using semantic chunking ===")
              SemanticChunker.chunk(text, client)
            :basic ->
              IO.puts("=== Using basic chunking ===")
              Chunker.chunk(text)
            :structured ->
              IO.puts("=== Using structured chunking ===")
              StructuredChunker.chunk(text)
          end

          # Create embeddings
          case Embedder.embed(client, chunks) do
            {:ok, embeddings} ->
              chunks_and_embeddings = Enum.zip(chunks, embeddings)
              case VectorDB.add_documents(chunks_and_embeddings) do
                {:ok, _ids} -> 
                  VectorDB.save()  # Ensure immediate persistence
                  {:ok, length(chunks)}
                {:error, reason} -> 
                  {:error, reason}
              end
            {:error, reason} ->
              {:error, reason}
          end
        {:error, reason} ->
          {:error, reason}
      end
    after
      # Clean up temp file
      File.rm(temp_path)
    end
  end

  defp answer_question_stream(question, _vector_db, client, live_view_pid) do
    try do
      with {:ok, query_embedding} <- Embedder.embed(client, question),
           {:ok, search_results} <- VectorDB.search(query_embedding, 5) do

        # Start streaming chat
        Task.start(fn ->
          case Chat.ask_stream(client, search_results, question) do
            {:ok, stream} ->
              stream
              |> Stream.each(fn chunk ->
                case chunk do
                  %{"message" => %{"content" => content}} when content != "" ->
                    send(live_view_pid, {:stream_chunk, content})
                  %{"done" => true} ->
                    send(live_view_pid, {:stream_complete})
                  _ ->
                    :ok
                end
              end)
              |> Stream.run()
            {:error, reason} ->
              send(live_view_pid, {:stream_error, reason})
          end
        end)

        {:ok, :started}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, "Unexpected error in streaming setup"}
      end
    rescue
      error -> {:error, "Exception: #{inspect(error)}"}
    end
  end

  defp answer_question(question, _vector_db, client) do
    with {:ok, query_embedding} <- Embedder.embed(client, question),
         {:ok, search_results} <- VectorDB.search(query_embedding, 5),
         {:ok, %{"message" => %{"content" => answer}}} <- Chat.ask(client, search_results, question) do
      {:ok, answer}
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, "Unexpected error: #{inspect(error)}"}
    end
  end

  defp chunking_strategy_options do
    [
      {"Semantic", :semantic},
      {"Basic", :basic},
      {"Structured", :structured}
    ]
  end

  defp chunking_toggle_color(:semantic), do: "bg-indigo-600"
  defp chunking_toggle_color(:basic), do: "bg-gray-400"
  defp chunking_toggle_color(:structured), do: "bg-green-600"

  defp chunking_toggle_position(:semantic), do: "translate-x-0"
  defp chunking_toggle_position(:basic), do: "translate-x-3"
  defp chunking_toggle_position(:structured), do: "translate-x-6"

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100">
      <div class="container mx-auto px-4 py-8">
        <!-- Header -->
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-gray-800 mb-2">RAG Document Q&A</h1>
          <p class="text-gray-600">Upload a PDF and ask questions about its content</p>
        </div>

        <!-- Upload Section -->
        <div class="max-w-2xl mx-auto mb-8">
          <div class="bg-white rounded-lg shadow-lg p-6">
            <h2 class="text-xl font-semibold text-gray-800 mb-4">Upload Document</h2>

            <!-- Chunking Strategy Toggle -->
            <div class="mb-4 p-3 bg-gray-50 rounded-lg">
              <div class="flex items-center justify-between">
                <div>
                  <label class="text-sm font-medium text-gray-700">Chunking Strategy:</label>
                  <p class="text-xs text-gray-500">
                    <%= case @chunking_strategy do %>
                      <% :semantic -> %>
                        Semantic - Groups similar sentences together (slower, more accurate)
                      <% :basic -> %>
                        Basic - Simple text splitting (faster)
                      <% :structured -> %>
                        Structured - Keeps related info together (best for transcripts, forms)
                    <% end %>
                  </p>
                </div>
                <div class="flex space-x-2">
                  <button
                    type="button"
                    phx-click="toggle_chunking"
                    class={"relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2 " <> chunking_toggle_color(@chunking_strategy)}
                  >
                    <span class={"pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out " <> chunking_toggle_position(@chunking_strategy)}></span>
                  </button>
                  <span class="text-xs text-gray-400">Switch</span>
                </div>
              </div>
              <div class="flex space-x-2 mt-2">
                <%= for {label, strategy} <- chunking_strategy_options() do %>
                  <span class={"px-2 py-1 rounded text-xs font-medium " <> if @chunking_strategy == strategy, do: "bg-indigo-600 text-white", else: "bg-gray-200 text-gray-600"}>
                    <%= label %>
                  </span>
                <% end %>
              </div>
            </div>

            <form phx-submit="upload" phx-change="validate" class="space-y-4">
              <div class="border-2 border-dashed border-gray-300 rounded-lg p-6 text-center hover:border-indigo-400 transition-colors">
                <.live_file_input upload={@uploads.pdf} class="hidden" />

                <%= if Enum.empty?(@uploads.pdf.entries) do %>
                  <div class="cursor-pointer" onclick={"document.querySelector('input[name=\"pdf\"]').click()"}>
                    <svg class="mx-auto h-12 w-12 text-gray-400" stroke="currentColor" fill="none" viewBox="0 0 48 48">
                      <path d="M28 8H12a4 4 0 00-4 4v20m32-12v8m0 0v8a4 4 0 01-4 4H12a4 4 0 01-4-4v-4m32-4l-3.172-3.172a4 4 0 00-5.656 0L28 28M8 32l9.172-9.172a4 4 0 015.656 0L28 28m0 0l4 4m4-24h8m-4-4v8m-12 4h.02" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
                    </svg>
                    <p class="mt-2 text-sm text-gray-600">
                      <span class="font-medium text-indigo-600">Click to upload</span> or drag and drop
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
                <button type="submit" class="w-full bg-indigo-600 text-white py-2 px-4 rounded-lg hover:bg-indigo-700 transition-colors font-medium">
                  Process Document
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
                  <span class="text-blue-800">Processing document...</span>
                </div>
              </div>
            <% end %>

            <%= if @uploaded_file do %>
              <div class="mt-4 p-4 bg-green-50 rounded-lg">
                <div class="flex items-center">
                  <svg class="h-5 w-5 text-green-600 mr-3" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
                  </svg>
                  <span class="text-green-800">Document "<%= @uploaded_file %>" processed successfully!</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Chat Section -->
        <%= if @vector_db != [] do %>
          <div class="max-w-4xl mx-auto">
            <div class="bg-white rounded-lg shadow-lg overflow-hidden">
              <!-- Chat Header -->
              <div class="bg-indigo-600 text-white px-6 py-4">
                <h2 class="text-xl font-semibold">Ask Questions</h2>
                <p class="text-indigo-200 text-sm">Ask anything about your uploaded document</p>
              </div>

              <!-- Messages -->
              <div class="h-96 overflow-y-auto p-6 space-y-4" id="messages-container">
                <%= if Enum.empty?(@messages) do %>
                  <div class="text-center text-gray-500 mt-8">
                    <svg class="mx-auto h-12 w-12 text-gray-400 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-3.582 8-8 8a8.959 8.959 0 01-4.906-1.405L3 21l2.595-5.094A8.959 8.959 0 013 12c0-4.418 3.582-8 8-8s8 3.582 8 8z" />
                    </svg>
                    <p>Start a conversation by asking a question about your document!</p>
                  </div>
                <% else %>
                  <%= for message <- @messages do %>
                    <div class={"flex #{if message.role == :user, do: "justify-end", else: "justify-start"}"}>
                      <div class={"max-w-xs lg:max-w-md px-4 py-2 rounded-lg #{if message.role == :user, do: "bg-indigo-600 text-white", else: "bg-gray-200 text-gray-800"}"}>
                        <p class="text-sm">
                          <%= message.content %>
                          <%= if Map.get(message, :streaming, false) do %>
                            <span class="inline-block w-2 h-4 bg-current animate-pulse ml-1">|</span>
                          <% end %>
                        </p>
                        <p class={"text-xs mt-1 #{if message.role == :user, do: "text-indigo-200", else: "text-gray-500"}"}>
                          <%= Calendar.strftime(message.timestamp, "%H:%M") %>
                          <%= if Map.get(message, :streaming, false) do %>
                            <span class="text-blue-500 ml-1">streaming...</span>
                          <% end %>
                        </p>
                      </div>
                    </div>
                  <% end %>
                <% end %>

                <%= if @processing and not Enum.empty?(@messages) do %>
                  <div class="flex justify-start">
                    <div class="bg-gray-200 text-gray-800 px-4 py-2 rounded-lg">
                      <div class="flex items-center">
                        <svg class="animate-spin h-4 w-4 text-gray-600 mr-2" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                        </svg>
                        <span class="text-sm">Thinking...</span>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>

              <!-- Input Form -->
              <div class="border-t bg-gray-50 px-6 py-4">
                <form phx-submit="ask_question" class="flex space-x-2">
                  <input
                    type="text"
                    name="question"
                    value={@current_question}
                    phx-change="update_question"
                    placeholder="Ask a question about your document..."
                    class="flex-1 border border-gray-300 rounded-lg px-4 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
                    disabled={@processing}
                  />
                  <button
                    type="submit"
                    disabled={@processing or @current_question == ""}
                    class="bg-indigo-600 text-white px-6 py-2 rounded-lg hover:bg-indigo-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
                  >
                    <%= if @processing do %>
                      <svg class="animate-spin h-5 w-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                      </svg>
                    <% else %>
                      Send
                    <% end %>
                  </button>
                </form>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <script>
      // Auto-scroll to bottom of messages
      function scrollToBottom() {
        const messagesContainer = document.getElementById('messages-container');
        if (messagesContainer) {
          messagesContainer.scrollTop = messagesContainer.scrollHeight;
        }
      }

      // Initial scroll
      scrollToBottom();

      // Auto-scroll when content updates
      const observer = new MutationObserver(scrollToBottom);
      const messagesContainer = document.getElementById('messages-container');
      if (messagesContainer) {
        observer.observe(messagesContainer, { childList: true, subtree: true });
      }

      // Handle flash fade-out effect
      window.addEventListener("phx:fade-flash", () => {
        const flashMessages = document.querySelectorAll('[role="alert"]');
        flashMessages.forEach(message => {
          message.style.transition = 'opacity 0.5s ease-out, transform 0.5s ease-out';
          message.style.opacity = '0';
          message.style.transform = 'translateY(-10px)';
        });
      });
    </script>
    """
  end
end
