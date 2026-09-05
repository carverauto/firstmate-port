defmodule FirstmatePortWeb.SteerDocs do
  @moduledoc """
  User docs served under `/steer/docs`. The markdown in `docs/` is the only
  copy: each page is read at compile time, so the served page and the repo
  file can never drift. Add a page by adding its markdown and one entry
  here.
  """

  @root Path.expand("../../..", __DIR__)

  @pages [
    {"fm-steer", "fm-steer CLI", "docs/fm-steer.md"},
    {"routing", "Routing", "docs/routing.md"},
    {"usage", "Usage and billing", "docs/usage.md"}
  ]

  for {slug, title, path} <- @pages do
    @external_resource Path.join(@root, path)

    defp read(unquote(slug)) do
      %{
        slug: unquote(slug),
        title: unquote(title),
        path: unquote(path),
        body: unquote(File.read!(Path.join(@root, path)))
      }
    end
  end

  defp read(_), do: nil

  @doc "Doc page for a slug, or `:error` when the slug is unknown."
  def fetch(slug) when is_binary(slug) do
    case read(slug) do
      nil -> :error
      page -> {:ok, page}
    end
  end

  @doc "Every doc page as `%{slug:, title:, path:}`, in nav order."
  def index do
    Enum.map(@pages, fn {slug, title, path} -> %{slug: slug, title: title, path: path} end)
  end
end
