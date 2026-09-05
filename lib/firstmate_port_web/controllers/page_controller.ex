defmodule FirstmatePortWeb.PageController do
  use FirstmatePortWeb, :controller

  def healthz(conn, _params) do
    text(conn, "ok")
  end
end
