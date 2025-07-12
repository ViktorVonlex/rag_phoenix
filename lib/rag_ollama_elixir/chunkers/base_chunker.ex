defmodule RagOllamaElixir.Chunkers.BaseChunker do
  @moduledoc """
  Smart chunker for PDF text.
  - Splits on double newlines (\\n\\n) for section structure.
  - Further splits long sections by periods or single newline.
  - Merges small chunks up to a target chunk size (in chars).
  """

  @behaviour RagOllamaElixir.Chunkers.ChunkerBehaviour

  @target_chunk_size 300   # Tunable

  @impl true
  def chunk(text, opts \\ []) do
    target_size = Keyword.get(opts, :chunk_size, @target_chunk_size)

    chunks = text
    |> String.split(~r/\n{2,}/)
    |> Enum.flat_map(&split_section/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> merge_small_chunks(target_size)

    {:ok, chunks}
  end

  @impl true
  def metadata do
    %{
      name: "Basic Chunking",
      description: "Simple text splitting with smart merging of small chunks",
      requires_client: false
    }
  end

  @impl true
  def validate_text(text) when is_binary(text) and byte_size(text) > 0, do: :ok
  def validate_text(_), do: {:error, "Text must be a non-empty string"}

  # For each section, split by period or single newline if it's long
  defp split_section(section) when byte_size(section) < @target_chunk_size, do: [section]
  defp split_section(section) do
    # Split by newlines or sentence boundary
    String.split(section, ~r/\n|(?<=[.?!])\s+/)
  end

  # Merge small chunks into larger ones, up to target_chunk_size
  defp merge_small_chunks(chunks, target_size) do
    Enum.reduce(chunks, {[], ""}, fn chunk, {acc, current} ->
      chunk = String.trim(chunk)
      cond do
        current == "" -> {acc, chunk}
        byte_size(current) + byte_size(chunk) + 1 < target_size ->
          {acc, current <> " " <> chunk}
        true ->
          {[current | acc], chunk}
      end
    end)
    |> (fn {acc, last} -> Enum.reverse([last | acc]) |> Enum.filter(&(&1 != "")) end).()
  end
end
