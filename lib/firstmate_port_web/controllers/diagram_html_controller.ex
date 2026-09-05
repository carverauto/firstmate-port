defmodule FirstmatePortWeb.DiagramHTMLController do
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Portal.Diagram

  def show(conn, %{"id" => id}) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""

    case Diagram.get(id, FirstmatePort.Tenancy.opts(conn.assigns.current_user)) do
      {:ok, diagram} ->
        if crawler?(ua) and is_nil(conn.assigns.current_user) do
          og(conn, diagram)
        else
          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, diagram.html)
        end

      {:error, _} ->
        conn |> put_status(:not_found) |> text("diagram not found")
    end
  end

  def card(conn, %{"id" => id}) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""
    actor = conn.assigns.current_user

    cond do
      actor ->
        send_card(conn, id, actor)

      crawler?(ua) ->
        send_card(conn, id, crawler_actor())

      true ->
        conn |> put_status(:unauthorized) |> text("sign in")
    end
  end

  defp send_card(conn, id, actor) do
    case Diagram.get(id, FirstmatePort.Tenancy.opts(actor)) do
      {:ok, %{png: png}} when is_binary(png) and png != "" ->
        conn
        |> put_resp_content_type("image/png")
        |> send_resp(200, png)

      {:ok, _} ->
        conn |> put_status(:not_found) |> text("no share card")

      {:error, _} ->
        conn |> put_status(:not_found) |> text("diagram not found")
    end
  end

  defp og(conn, diagram) do
    url = Application.get_env(:firstmate_port, :public_url, "") <> "/d/" <> diagram.id
    image = url <> "/card.png"

    html = """
    <!doctype html><html><head>
    <meta property="og:title" content="#{Plug.HTML.html_escape(diagram.title)}">
    <meta property="og:url" content="#{url}">
    <meta property="og:image" content="#{image}">
    <title>#{Plug.HTML.html_escape(diagram.title)}</title>
    </head><body>Sign in to view the interactive diagram.</body></html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp crawler?(ua) do
    ua = String.downcase(ua)

    Enum.any?(
      ["discordbot", "twitterbot", "slackbot", "facebookexternalhit"],
      &String.contains?(ua, &1)
    )
  end

  defp crawler_actor, do: %{role: :human, email: "crawler@localhost"}
end
