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

  def doc_fm_steer(conn, _params) do
    render(conn, :doc_fm_steer, page_title: "fm-steer CLI")
  end

  def doc_routing(conn, _params) do
    render(conn, :doc_routing, page_title: "routing")
  end

  def doc_usage(conn, _params) do
    render(conn, :doc_usage, page_title: "usage and billing")
  end
end
