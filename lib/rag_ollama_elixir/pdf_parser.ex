defmodule RagOllamaElixir.PDFParser do
  @moduledoc "Extracts text from PDF using pdftotext CLI"

  def extract_text(pdf_path) do
    case System.cmd("pdftotext", ["-layout", pdf_path, "-"]) do
      {text, 0} -> {:ok, text}
      {error_msg, _} -> {:error, error_msg}
    end
  end
end
