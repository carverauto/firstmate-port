defmodule FirstmatePortWeb.SteerController do
  @moduledoc "Public marketing landing page and user docs for fm-steer."
  use FirstmatePortWeb, :controller

  plug :put_layout, html: {FirstmatePortWeb.Layouts, :marketing}

  def landing(conn, _params) do
    render(conn, :landing, page_title: "fm-steer")
  end

  def docs(conn, _params) do
    render(conn, :docs_index, page_title: "docs")
  end

  def doc(conn, %{"page" => slug}) do
    case FirstmatePortWeb.SteerDocs.fetch(slug) do
      {:ok, doc} ->
        render(conn, :doc, page_title: doc.title, doc: doc)

      :error ->
        conn |> put_status(:not_found) |> text("not found")
    end
  end
end
