defmodule FirstmatePortWeb.DiagramHTMLController do
  @moduledoc """
  Serves an uploaded Archify diagram.

  A diagram is tenant data, so reading one needs an actor. A visitor who is not
  signed in is sent to sign in and returned here afterwards rather than being
  told the diagram does not exist - a link pasted into a chat should land on the
  diagram, not on a 404 that looks like the upload failed. Link-unfurling
  crawlers get the Open Graph card instead, since they cannot sign in.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.Portal.Diagram

  def show(conn, %{"id" => id}) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""

    cond do
      is_nil(conn.assigns.current_user) and crawler?(ua) ->
        case Diagram.get(id, FirstmatePort.Tenancy.opts(crawler_actor())) do
          {:ok, diagram} -> og(conn, diagram)
          {:error, _} -> not_found(conn)
        end

      is_nil(conn.assigns.current_user) ->
        conn
        |> put_session(:return_to, conn.request_path)
        |> redirect(to: ~p"/login")

      true ->
        case Diagram.get(id, FirstmatePort.Tenancy.opts(conn.assigns.current_user)) do
          {:ok, diagram} ->
            conn
            |> put_resp_content_type("text/html")
            |> send_resp(200, diagram.html)

          {:error, _} ->
            not_found(conn)
        end
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

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("diagram not found")
end
