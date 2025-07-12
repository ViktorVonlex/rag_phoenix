defmodule RagOllamaElixirWeb.RagLive do
  use RagOllamaElixirWeb, :live_view

  alias RagOllamaElixir.{PDFParser, Embedder, Chat, VectorDB}
  alias RagOllamaElixir.{Conversations}
  alias RagOllamaElixir.Chunkers.{BaseChunker, SemanticChunker, StructuredChunker}

  @uploads_dir "priv/static/uploads"

  def mount(params, _session, socket) do
    File.mkdir_p!(@uploads_dir)

    # Get the current user from the socket (provided by auth)
    current_user = socket.assigns.current_user

    # Check if we're loading a specific conversation
    conversation = case params["conversation_id"] do
      nil -> nil
      conversation_id ->
        Conversations.get_user_conversation(current_user.id, conversation_id)
    end

    # Load user's conversations for the sidebar
    user_conversations = Conversations.list_conversations(current_user)

    # Check if conversation has embeddings loaded
    conversation_has_embeddings = case conversation do
      %{id: conv_id} ->
        case VectorDB.load_conversation(conv_id) do
          {:ok, has_vectors} -> has_vectors
          _ -> false
        end
      _ -> false
    end

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:conversation, conversation)
      |> assign(:user_conversations, user_conversations)
      |> assign(:messages, conversation && normalize_messages(conversation.messages) || [])
      |> assign(:current_question, "")
      |> assign(:vector_db, (conversation && conversation_has_embeddings && :persistent) || [])
      |> assign(:processing, false)
      |> assign(:ollama_client, nil)
      |> assign(:uploaded_file, conversation && conversation.document_name)
      |> assign(:chunking_strategy, conversation && String.to_atom(conversation.chunking_strategy || "semantic") || :semantic)
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
      user_message = %{role: :user, content: question, timestamp: DateTime.utc_now() |> DateTime.truncate(:second)}
      messages = socket.assigns.messages ++ [user_message]

      # Start streaming assistant message
      assistant_message = %{role: :assistant, content: "", timestamp: DateTime.utc_now() |> DateTime.truncate(:second), streaming: true}
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

  def handle_event("set_chunking_strategy", %{"strategy" => strategy}, socket) do
    new_strategy = String.to_atom(strategy)
    {:noreply, assign(socket, :chunking_strategy, new_strategy)}
  end

  def handle_event("delete_conversation", %{"id" => conversation_id}, socket) do
    current_user = socket.assigns.current_user

    case Conversations.get_user_conversation(current_user.id, conversation_id) do
      nil ->
        socket = put_flash(socket, :error, "Conversation not found")
        {:noreply, socket}

      conversation ->
        case Conversations.delete_conversation(conversation) do
          {:ok, _} ->
            # Refresh conversations list and redirect to main page if we deleted the current conversation
            user_conversations = Conversations.list_conversations(current_user)

            socket =
              socket
              |> assign(:user_conversations, user_conversations)
              |> put_flash(:info, "Conversation deleted successfully")

            # If we deleted the current conversation, redirect to main page
            if socket.assigns.conversation && socket.assigns.conversation.id == String.to_integer(conversation_id) do
              {:noreply, push_navigate(socket, to: ~p"/rag")}
            else
              {:noreply, socket}
            end

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to delete conversation")
            {:noreply, socket}
        end
    end
  end

  def handle_event("new_chat", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/rag")}
  end

  def handle_info({:process_upload, uploaded_files}, socket) do
    IO.puts("=== HANDLE_INFO: Processing upload started ===")
    IO.inspect(uploaded_files, label: "Uploaded files")

    case uploaded_files do
      [{temp_path, filename}] ->
        IO.puts("Processing file: #{filename} at #{temp_path}")
        case process_pdf_file(temp_path, socket.assigns.ollama_client, socket.assigns.chunking_strategy, socket.assigns.conversation && socket.assigns.conversation.id) do
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
    case answer_question_stream(question, socket.assigns.vector_db, socket.assigns.ollama_client, self(), socket.assigns.conversation && socket.assigns.conversation.id) do
      {:ok, _task} ->
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

  # Handle streaming messages from Ollama
  def handle_info({pid, {:data, %{"done" => false} = data}}, socket) when is_pid(pid) do
    # Extract the content from the streaming chunk
    content = get_in(data, ["message", "content"]) || ""

    # Update the streaming message with new content
    if socket.assigns.streaming_message do
      updated_content = socket.assigns.streaming_message.content <> content
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

  def handle_info({pid, {:data, %{"done" => true} = _data}}, socket) when is_pid(pid) do
    # Streaming is complete
    if socket.assigns.streaming_message do
      # Mark the message as no longer streaming
      final_message = Map.delete(socket.assigns.streaming_message, :streaming)
      messages = List.update_at(socket.assigns.messages, -1, fn _ -> final_message end)

      # Save the conversation and messages to database
      socket = save_conversation_and_messages(socket, messages)

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

  # Handle successful completion of the streaming task
  def handle_info({ref, {:ok, %Req.Response{status: 200}}}, socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  # Handle Ollama streaming completion message
  def handle_info({ref, {:ok, %{"done" => true} = _final_data}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    # Mark streaming as complete if we have a streaming message
    if socket.assigns.streaming_message do
      final_message = Map.delete(socket.assigns.streaming_message, :streaming)
      messages = List.update_at(socket.assigns.messages, -1, fn _ -> final_message end)

      socket = save_conversation_and_messages(socket, messages)

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

  # Handle errors in the streaming task
  def handle_info({ref, {:error, reason}}, socket) do
    Process.demonitor(ref, [:flush])
    IO.puts("=== Stream error: #{inspect(reason)} ===")
    socket =
      socket
      |> assign(:processing, false)
      |> assign(:streaming_message, nil)
      |> put_flash(:error, "Streaming failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  def handle_info(:start_flash_fade, socket) do
    send(self(), :phx_flash_fade)
    {:noreply, socket}
  end

  def handle_info(:phx_flash_fade, socket) do
    {:noreply, socket}
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  defp process_pdf_file(temp_path, client, chunking_strategy, conversation_id) do
    IO.puts("=== Starting PDF processing with strategy: #{chunking_strategy} ===")

    # Clear any existing vectors for this conversation (or all if no conversation)
    if conversation_id do
      VectorDB.clear(conversation_id)
      IO.puts("=== Cleared existing vectors for conversation #{conversation_id} ===")
    else
      VectorDB.clear()
      IO.puts("=== Cleared all existing vectors ===")
    end

    try do
      # Parse PDF
      case PDFParser.extract_text(temp_path) do
        {:ok, content} ->
          IO.puts("=== PDF parsed successfully, content length: #{String.length(content)} ===")

          # Chunk content based on strategy
          chunks = case chunking_strategy do
            strategy when strategy in [:semantic, "semantic"] ->
              case SemanticChunker.chunk(content, client: client) do
                {:ok, semantic_chunks} -> semantic_chunks
                {:error, reason} ->
                  IO.puts("=== Semantic chunking failed: #{reason}, falling back to basic ===")
                  {:ok, fallback_chunks} = BaseChunker.chunk(content)
                  fallback_chunks
              end

            strategy when strategy in [:basic, "basic"] ->
              {:ok, basic_chunks} = BaseChunker.chunk(content)
              basic_chunks

            strategy when strategy in [:structured, "structured"] ->
              {:ok, structured_chunks} = StructuredChunker.chunk(content)
              structured_chunks

            _ ->
              IO.puts("=== Unknown strategy #{chunking_strategy}, using semantic ===")
              case SemanticChunker.chunk(content, client: client) do
                {:ok, semantic_chunks} -> semantic_chunks
                {:error, reason} ->
                  IO.puts("=== Semantic chunking failed: #{reason}, falling back to basic ===")
                  {:ok, fallback_chunks} = BaseChunker.chunk(content)
                  fallback_chunks
              end
          end

          IO.puts("=== Created #{length(chunks)} chunks ===")

          # Generate embeddings and store in persistent VectorDB
          chunk_embeddings = Enum.with_index(chunks)
          |> Enum.map(fn {chunk, index} ->
            IO.puts("=== Processing chunk #{index + 1}/#{length(chunks)} ===")
            IO.puts("Chunk preview: #{String.slice(chunk, 0, 100)}...")

            case Embedder.embed(client, chunk) do
              {:ok, embedding} when is_list(embedding) ->
                IO.puts("=== Successfully embedded chunk #{index + 1}, embedding length: #{length(embedding)} ===")
                %{text: chunk, embedding: embedding}
              {:ok, other_embedding} ->
                IO.puts("=== Unexpected embedding format for chunk #{index + 1}: #{inspect(other_embedding)} ===")
                nil
              {:error, reason} ->
                IO.puts("=== Failed to embed chunk #{index + 1}: #{reason} ===")
                nil
            end
          end)
          |> Enum.filter(& &1)

          IO.puts("=== Generated #{length(chunk_embeddings)} embeddings ===")

          # Store in persistent vector database
          Enum.each(chunk_embeddings, fn %{text: text, embedding: embedding} ->
            IO.puts("=== Storing chunk with embedding type: #{inspect(embedding |> Enum.take(3))} (showing first 3 values) ===")
            VectorDB.store(text, embedding, conversation_id)
          end)

          {:ok, length(chunk_embeddings)}

        {:error, reason} ->
          IO.puts("=== PDF parsing failed: #{reason} ===")
          {:error, reason}
      end
    rescue
      error ->
        IO.puts("=== Exception during PDF processing: #{inspect(error)} ===")
        {:error, "Processing failed: #{inspect(error)}"}
    after
      # Clean up temp file
      File.rm(temp_path)
    end
  end

  defp answer_question_stream(question, _vector_db, client, _live_view_pid, conversation_id) do
    try do
      # Get embeddings for the question
      case Embedder.embed(client, question) do
        {:ok, query_embedding} ->
          # Search the persistent vector database
          case VectorDB.search(query_embedding, 5, conversation_id) do
            {:ok, search_results} ->
              IO.puts("=== Found #{length(search_results)} relevant chunks ===")

              # Start streaming chat
              case Chat.ask_stream(client, search_results, question, self()) do
                {:ok, task} ->
                  {:ok, task}
                error ->
                  {:error, "Failed to start streaming: #{inspect(error)}"}
              end

            {:error, reason} ->
              {:error, "Search failed: #{reason}"}
          end

        {:error, reason} ->
          {:error, "Embedding failed: #{reason}"}
      end
    rescue
      error ->
        {:error, "Exception: #{inspect(error)}"}
    end
  end

  defp save_conversation_and_messages(socket, messages) do
    current_user = socket.assigns.current_user
    IO.puts("=== SAVING CONVERSATION ===")
    IO.puts("Current conversation: #{inspect(socket.assigns.conversation)}")
    IO.puts("Messages count: #{length(messages)}")

    try do
      # Get or create conversation
      conversation = case socket.assigns.conversation do
        nil ->
          IO.puts("=== CREATING NEW CONVERSATION ===")
          # Create new conversation from first user message
          user_message = Enum.find(messages, &(&1.role == :user))
          if user_message do
            title = generate_conversation_title(user_message.content)
            document_name = socket.assigns.uploaded_file
            chunking_strategy = to_string(socket.assigns.chunking_strategy)

            IO.puts("Title: #{title}")
            IO.puts("Document: #{document_name}")
            IO.puts("Strategy: #{chunking_strategy}")

            case Conversations.start_conversation(current_user.id, title, user_message.content, document_name, chunking_strategy) do
              {:ok, conv} ->
                IO.puts("=== CONVERSATION CREATED SUCCESSFULLY ===")
                IO.inspect(conv, label: "New conversation")
                conv
              {:error, reason} ->
                IO.puts("=== CONVERSATION CREATION FAILED ===")
                IO.inspect(reason, label: "Error")
                nil
            end
          else
            IO.puts("=== NO USER MESSAGE FOUND ===")
            nil
          end

        existing_conversation ->
          IO.puts("=== USING EXISTING CONVERSATION ===")
          existing_conversation
      end

      if conversation do
        # Save any new messages (assistant responses)
        assistant_messages = Enum.filter(messages, &(&1.role == :assistant))
        IO.puts("=== SAVING #{length(assistant_messages)} ASSISTANT MESSAGES ===")
        Enum.each(assistant_messages, fn msg ->
          # Check if message already exists to avoid duplicates
          existing_messages = Conversations.get_conversation_messages(conversation)
          unless Enum.any?(existing_messages, &(&1.content == msg.content)) do
            case Conversations.add_message_to_conversation(conversation, "assistant", msg.content) do
              {:ok, _} ->
                IO.puts("=== MESSAGE SAVED ===")
              {:error, reason} ->
                IO.puts("=== MESSAGE SAVE FAILED ===")
                IO.inspect(reason)
            end
          end
        end)

        # Update socket assigns
        updated_conversations = Conversations.list_conversations(current_user)
        IO.puts("=== UPDATED CONVERSATIONS COUNT: #{length(updated_conversations)} ===")
        socket
        |> assign(:conversation, conversation)
        |> assign(:user_conversations, updated_conversations)
      else
        IO.puts("=== NO CONVERSATION TO SAVE ===")
        socket
      end
    rescue
      error ->
        IO.puts("=== EXCEPTION IN SAVE_CONVERSATION_AND_MESSAGES ===")
        IO.inspect(error, label: "Exception")
        IO.inspect(__STACKTRACE__, label: "Stacktrace")
        socket  # If anything fails, just return the socket unchanged
    end
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn message ->
      # Convert role string to atom for consistency with LiveView messages
      role_atom = case message.role do
        "user" -> :user
        "assistant" -> :assistant
        atom when is_atom(atom) -> atom  # Already an atom
        _ -> :assistant  # fallback
      end

      %{
        role: role_atom,
        content: message.content,
        timestamp: message.inserted_at
      }
    end)
  end

  defp generate_conversation_title(user_message) do
    # Generate a short title from the user's first message
    words = user_message |> String.split(" ") |> Enum.take(6)
    title = Enum.join(words, " ")

    if String.length(title) > 50 do
      String.slice(title, 0, 47) <> "..."
    else
      title
    end
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <!-- Upload Section (only show if no document uploaded) -->
      <%= if @uploaded_file == nil do %>
        <div class="flex-1 flex items-center justify-center p-8">
          <div class="w-full max-w-4xl">
            <div class="text-center mb-8">
              <h2 class="text-2xl font-bold text-gray-800 mb-2">Upload Document</h2>
              <p class="text-gray-600">Upload a PDF and start asking questions about its content</p>
            </div>

            <!-- Chunking Strategy Selector -->
            <div class="mb-6 p-4 bg-gray-50 rounded-lg max-w-2xl mx-auto">
              <div>
                <label class="text-sm font-medium text-gray-700 mb-3 block">Chunking Strategy</label>
                <div class="grid grid-cols-3 gap-2 bg-white p-1 rounded-lg border">
                  <button
                    type="button"
                    phx-click="set_chunking_strategy"
                    phx-value-strategy="semantic"
                    class={"px-3 py-2 text-sm font-medium rounded-md transition-all duration-200 " <> if @chunking_strategy in [:semantic, "semantic"], do: "bg-indigo-600 text-white shadow-sm", else: "text-gray-700 hover:text-gray-900 hover:bg-gray-100"}
                  >
                    Semantic
                  </button>
                  <button
                    type="button"
                    phx-click="set_chunking_strategy"
                    phx-value-strategy="basic"
                    class={"px-3 py-2 text-sm font-medium rounded-md transition-all duration-200 " <> if @chunking_strategy in [:basic, "basic"], do: "bg-indigo-600 text-white shadow-sm", else: "text-gray-700 hover:text-gray-900 hover:bg-gray-100"}
                  >
                    Basic
                  </button>
                  <button
                    type="button"
                    phx-click="set_chunking_strategy"
                    phx-value-strategy="structured"
                    class={"px-3 py-2 text-sm font-medium rounded-md transition-all duration-200 " <> if @chunking_strategy in [:structured, "structured"], do: "bg-indigo-600 text-white shadow-sm", else: "text-gray-700 hover:text-gray-900 hover:bg-gray-100"}
                  >
                    Structured
                  </button>
                </div>
                <p class="text-xs text-gray-500 mt-2">
                  <%= case @chunking_strategy do %>
                    <% strategy when strategy in [:semantic, "semantic"] -> %>
                      Groups similar sentences together using AI embeddings
                    <% strategy when strategy in [:basic, "basic"] -> %>
                      Simple text splitting by character count
                    <% strategy when strategy in [:structured, "structured"] -> %>
                      Preserves document structure and related information
                    <% _ -> %>
                      Groups similar sentences together using AI embeddings
                  <% end %>
                </p>
              </div>
            </div>

            <div class="max-w-2xl mx-auto">
              <form phx-submit="upload" phx-change="validate" class="space-y-6">
                <div class="border-2 border-dashed border-gray-300 rounded-xl p-8 text-center hover:border-indigo-400 transition-colors bg-white shadow-sm">
                  <.live_file_input upload={@uploads.pdf} class="hidden" />

                  <%= if Enum.empty?(@uploads.pdf.entries) do %>
                    <div class="cursor-pointer" onclick={"document.querySelector('input[name=\"pdf\"]').click()"}>
                      <svg class="mx-auto h-16 w-16 text-gray-400 mb-4" stroke="currentColor" fill="none" viewBox="0 0 48 48">
                        <path d="M28 8H12a4 4 0 00-4 4v20m32-12v8m0 0v8a4 4 0 01-4 4H12a4 4 0 01-4-4v-4m32-4l-3.172-3.172a4 4 0 00-5.656 0L28 28M8 32l9.172-9.172a4 4 0 015.656 0L28 28m0 0l4 4m4-24h8m-4-4v8m-12 4h.02" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
                      </svg>
                      <p class="text-lg text-gray-600 mb-2">
                        <span class="font-semibold text-indigo-600">Click to upload</span> or drag and drop
                      </p>
                      <p class="text-sm text-gray-500">PDF files only (max 50MB)</p>
                    </div>
                  <% else %>
                    <%= for entry <- @uploads.pdf.entries do %>
                      <div class="flex items-center justify-between p-4 bg-gray-50 rounded-lg">
                        <div class="flex items-center">
                          <div class="flex items-center">
                            <svg class="h-10 w-10 text-red-600 mr-4" fill="currentColor" viewBox="0 0 20 20">
                              <path fill-rule="evenodd" d="M4 4a2 2 0 012-2h4.586A2 2 0 0112 2.586L15.414 6A2 2 0 0116 7.414V16a2 2 0 01-2 2H6a2 2 0 01-2-2V4z" clip-rule="evenodd" />
                            </svg>
                            <div>
                              <p class="text-base font-medium text-gray-900">{entry.client_name}</p>
                              <p class="text-sm text-gray-500">{Float.round(entry.client_size / 1024 / 1024, 2)} MB</p>
                            </div>
                          </div>
                        </div>
                        <button type="button" phx-click="remove_upload" phx-value-ref={entry.ref} class="text-red-500 hover:text-red-700 p-1">
                          <svg class="h-6 w-6" fill="currentColor" viewBox="0 0 20 20">
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
                  <p class="text-blue-800 font-medium">Processing document...</p>
                </div>
              </div>
            <% end %>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Chat Messages -->
      <div class="flex-1 overflow-y-auto p-6" id="messages-container">
        <%= if @uploaded_file && !Enum.empty?(@messages) do %>
          <div class="space-y-4 max-w-4xl mx-auto">
            <%= for message <- @messages do %>
              <div class={"flex " <> if message.role == :user, do: "justify-end", else: "justify-start"}>
                <div class={"max-w-2xl rounded-lg px-4 py-3 " <> if message.role == :user, do: "bg-indigo-600 text-white", else: "bg-gray-100 text-gray-900"}>
                  <div class="whitespace-pre-line leading-relaxed">
                    {String.trim(message.content)}
                    <%= if Map.get(message, :streaming, false) do %>
                      <span class="animate-pulse">▊</span>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="flex items-center justify-center h-full text-gray-500">
            <%= if @uploaded_file do %>
              <div class="text-center">
                <p class="text-lg font-medium">Document ready!</p>
                <p class="text-sm">Ask a question about <strong>{@uploaded_file}</strong></p>
              </div>
            <% else %>
              <div class="text-center">
                <p class="text-lg font-medium">Welcome to RAG Chat</p>
                <p class="text-sm">Upload a document to get started</p>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Question Input (only show if document uploaded) -->
      <%= if @uploaded_file do %>
        <div class="border-t border-gray-200 p-6">
          <form phx-submit="ask_question" class="flex space-x-3">
            <input
              type="text"
              name="question"
              value={@current_question}
              phx-change="update_question"
              placeholder="Ask a question about your document..."
              disabled={@processing}
              class="flex-1 border border-gray-300 rounded-lg px-4 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-500 disabled:bg-gray-100"
            />
            <button
              type="submit"
              disabled={@processing or @current_question == ""}
              class="bg-indigo-600 text-white px-6 py-2 rounded-lg hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors font-medium"
            >
              <%= if @processing do %>
                <svg class="animate-spin h-5 w-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 714 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
              <% else %>
                Send
              <% end %>
            </button>
          </form>
        </div>
      <% end %>
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
    </script>
    """
  end
end
