defmodule RagOllamaElixirWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use RagOllamaElixirWeb, :controller` and
  `use RagOllamaElixirWeb, :live_view`.
  """
  use RagOllamaElixirWeb, :html

  embed_templates "layouts/*"

  @doc """
  Formats a DateTime for display in the conversation sidebar.
  """
  def format_date(%DateTime{} = datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 ->
        "Just now"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes}m ago"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours}h ago"

      diff_seconds < 604800 ->
        days = div(diff_seconds, 86400)
        "#{days}d ago"

      true ->
        Calendar.strftime(datetime, "%m/%d/%y")
    end
  end

  def format_date(%NaiveDateTime{} = naive_datetime) do
    naive_datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_date()
  end

  def format_date(nil), do: ""
end
