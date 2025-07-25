defmodule RagOllamaElixir.Chunkers.StructuredChunker do
  @moduledoc """
  A chunker specialized for structured documents like transcripts, invoices, forms, etc.
  Attempts to keep related information together by detecting patterns and reconstructing
  logical groups.
  """

  @behaviour RagOllamaElixir.Chunkers.ChunkerBehaviour

  @impl true
  def chunk(text, _opts \\ []) do
    chunks = do_chunk(text)
    {:ok, chunks}
  end

  @impl true
  def metadata do
    %{
      name: "Structured Chunking",
      description: "Specialized chunking for structured documents like transcripts and forms",
      requires_client: false
    }
  end

  @impl true
  def validate_text(text) when is_binary(text) and byte_size(text) > 0, do: :ok
  def validate_text(_), do: {:error, "Text must be a non-empty string"}

  # Private implementation
  defp do_chunk(text) do
    # Clean and normalize the text
    text = clean_text(text)

    # Try to detect if this looks like a transcript/academic record
    if transcript_pattern?(text) do
      chunk_transcript(text)
    else
      # Fall back to semantic-aware chunking for other structured docs
      chunk_structured_fallback(text)
    end
  end

  defp clean_text(text) do
    text
    # Don't normalize whitespace too aggressively - layout flag preserves important spacing
    |> String.replace(~r/\r\n|\r/, "\n")
    |> String.trim()
  end

  defp transcript_pattern?(text) do
    # Look for common transcript indicators
    indicators = [
      ~r/academic record/i,
      ~r/transcript/i,
      ~r/course title/i,
      ~r/credits?\s+grade/i,
      ~r/gpa/i,
      ~r/semester/i
    ]

    Enum.any?(indicators, &Regex.match?(&1, text))
  end

  defp chunk_transcript(text) do
    chunks = []

    # Extract header information (student info, university, etc.)
    header_chunk = extract_header_info(text)
    chunks = if header_chunk, do: [header_chunk | chunks], else: chunks

    # Extract course and grade information together
    course_grade_chunks = extract_course_grade_info(text)
    chunks = chunks ++ course_grade_chunks

    # Extract summary information (total credits, GPA, etc.)
    summary_chunk = extract_summary_info(text)
    chunks = if summary_chunk, do: chunks ++ [summary_chunk], else: chunks

    # Extract any remaining important info
    remarks_chunk = extract_remarks(text)
    chunks = if remarks_chunk, do: chunks ++ [remarks_chunk], else: chunks

    # Ensure we have at least some chunks
    if Enum.empty?(chunks) do
      # Fall back to basic chunking if pattern matching fails
      {:ok, fallback_chunks} = RagOllamaElixir.Chunkers.BaseChunker.chunk(text, [])
      fallback_chunks
    else
      chunks
    end
  end

  defp extract_header_info(text) do
    # Extract student and institution information
    patterns = [
      ~r/name in full\s*:?\s*([^\n]+)/i,
      ~r/date of birth\s*:?\s*([^\n]+)/i,
      ~r/date of admission\s*:?\s*([^\n]+)/i,
      ~r/college\/school\s*:?\s*([^\n]+)/i,
      ~r/department\s*:?\s*([^\n]+)/i,
      ~r/receiver\s*:?\s*([^\n]+)/i
    ]

    extracted_info =
      patterns
      |> Enum.map(fn pattern ->
        case Regex.run(pattern, text) do
          [full_match, _] -> full_match
          _ -> nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    if not Enum.empty?(extracted_info) do
      # Also include university info
      university_info = extract_university_info(text)
      all_info = [university_info | extracted_info] |> Enum.filter(&(&1 != nil))
      Enum.join(all_info, ". ")
    else
      nil
    end
  end

  defp extract_university_info(text) do
    # Look for university name and address
    university_patterns = [
      ~r/([A-Z][A-Z\s&]+UNIVERSITY)/,
      ~r/(\d+-\d+,\s*[^,]+,\s*[^,]+,?[^,]*Korea)/i
    ]

    university_patterns
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, text) do
        [_, match] -> match
        _ -> nil
      end
    end)
  end

  defp extract_course_grade_info(text) do
    # Try to match courses with their grades

    # Look for semester sections
    semester_pattern = ~r/(\d+(?:st|nd|rd|th)?\s+semester\s+\d+)/i
    semester_matches = Regex.scan(semester_pattern, text)

    if not Enum.empty?(semester_matches) do
      # For each semester, try to extract course-grade pairs
      Enum.flat_map(semester_matches, fn [semester_text, _] ->
        extract_semester_courses(text, semester_text)
      end)
    else
      # Try to extract courses and grades more generally
      extract_general_course_info(text)
    end
  end

  defp extract_semester_courses(text, semester_text) do
    # Find the position of this semester in the text
    case String.split(text, semester_text, parts: 2) do
      [_, after_semester] ->
        # With -layout flag, courses and grades should be on the same lines
        course_grade_lines = extract_course_grade_lines(after_semester)
        if not Enum.empty?(course_grade_lines) do
          formatted_info = "#{semester_text}:\n" <> Enum.join(course_grade_lines, "\n")
          [formatted_info]
        else
          []
        end
      _ -> []
    end
  end

  defp extract_course_grade_lines(text) do
    # Apply whitespace normalization for better parsing
    normalized_lines = text
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))

    # Group course-related lines together
    course_lines = normalized_lines
    |> Enum.filter(fn line ->
      # Look for lines that contain course patterns (more flexible now with normalized spacing)
      has_course_marker = String.match?(line, ~r/^\*/) or
                         String.contains?(line, "Course Title") or
                         String.match?(line, ~r/[A-Z][A-Za-z\s:&]+(Program|Learning|Vision|Processing|Science|Studies|Analysis|Korean|Machine|Deep|Introduction)/)
      has_grade_pattern = String.match?(line, ~r/\b[A-F][+\-]?\b/) or
                         String.match?(line, ~r/\b\d+\s+[A-F][+\-]?\b/)

      has_course_marker or has_grade_pattern
    end)

    # Try to detect and group course table sections
    if has_course_table_pattern?(normalized_lines) do
      extract_course_table_section(normalized_lines)
    else
      course_lines |> Enum.take(10)  # Limit to reasonable number
    end
  end

  # Detect if we have a course table pattern
  defp has_course_table_pattern?(lines) do
    Enum.any?(lines, fn line ->
      String.contains?(line, "Course Title") and String.contains?(line, "Credits") and String.contains?(line, "Grade")
    end)
  end

  # Extract course table as a single coherent chunk
  defp extract_course_table_section(lines) do
    # Find the table header
    header_index = Enum.find_index(lines, fn line ->
      String.contains?(line, "Course Title") and String.contains?(line, "Credits")
    end)

    if header_index do
      # Get table header and subsequent course lines
      table_lines = lines
      |> Enum.drop(header_index)
      |> Enum.take_while(fn line ->
        # Continue until we hit a clearly non-course line
        not String.match?(line, ~r/^(Remarks|Total Credits|The asterisk|This PDF|Page \d+)/i)
      end)
      |> Enum.filter(fn line ->
        # Keep header, semester markers, course lines, and summary lines
        String.contains?(line, "Course Title") or
        String.contains?(line, "Semester") or
        String.match?(line, ~r/^\*/) or
        String.match?(line, ~r/(TERM|Credits|GP|GPA)/) or
        (String.contains?(line, " A") or String.contains?(line, " B") or String.contains?(line, " C"))
      end)

      table_lines
    else
      # Fallback to individual course lines
      lines |> Enum.filter(&String.match?(&1, ~r/^\*/)) |> Enum.take(10)
    end
  end

  defp extract_general_course_info(text) do
    # With layout formatting, look for lines with both courses and grades
    course_grade_lines = extract_course_grade_lines(text)
    if not Enum.empty?(course_grade_lines) do
      formatted_info = "Academic Record:\n" <> Enum.join(course_grade_lines, "\n")
      [formatted_info]
    else
      []
    end
  end

  defp extract_summary_info(text) do
    # Extract GPA, total credits, etc.
    summary_patterns = [
      ~r/total credits\s*:?\s*(\d+)/i,
      ~r/cumulative grade point average\s*:?\s*([\d.\/\(\)\s]+)/i,
      ~r/gpa\s*:?\s*([\d.]+)/i,
      ~r/term\s*:\s*credits\s*:\s*(\d+)/i
    ]

    extracted_summary =
      summary_patterns
      |> Enum.map(fn pattern ->
        case Regex.run(pattern, text) do
          [full_match, _] -> full_match
          _ -> nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    if not Enum.empty?(extracted_summary) do
      Enum.join(extracted_summary, ". ")
    else
      nil
    end
  end

  defp extract_remarks(text) do
    # Extract remarks section
    case Regex.run(~r/remarks\s*:?\s*(.+?)(?=\n\n|\z)/is, text) do
      [_, remarks] -> "Remarks: #{String.trim(remarks)}"
      _ -> nil
    end
  end

  defp chunk_structured_fallback(text) do
    # For non-transcript structured documents, use a different approach
    text
    |> String.split(~r/\n\s*\n/)  # Split on paragraph breaks
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn chunk -> String.length(chunk) > 10 end)
    |> Enum.chunk_every(2, 1, :discard)  # Overlap paragraphs
    |> Enum.map(fn chunks -> Enum.join(chunks, " ") end)
  end
end
