defmodule FirstmatePortWeb.LegalController do
  @moduledoc """
  Serves the public terms and privacy pages.

  These are the two URLs Discord's Developer Portal asks for before an
  application can be distributed, so they have to answer 200 to a signed-out
  GET from the public internet — no session, no allowlist, no redirect to
  `/login`. That is the whole reason this is a plain controller in the public
  scope rather than another LiveView behind `RequireUser`.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.Legal

  def terms(conn, _params) do
    render_legal(conn, :terms, "Terms of Service")
  end

  def privacy(conn, _params) do
    render_legal(conn, :privacy, "Privacy Policy")
  end

  defp render_legal(conn, template, title) do
    conn
    # Static documents that change on deploy, not per request. Let the browser
    # and Cloudflare hold them briefly so a burst of Discord or crawler traffic
    # does not reach Phoenix at all.
    |> put_resp_header("cache-control", "public, max-age=300")
    |> assign(:page_title, title)
    |> assign(:operator, Legal.operator())
    |> assign(:contact_email, Legal.contact_email())
    |> assign(:governing_law, Legal.governing_law())
    |> assign(:updated_on, Legal.updated_on())
    |> assign(:service_name, Legal.service_name())
    |> render(template)
  end
end
