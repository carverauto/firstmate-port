defmodule FirstmatePortWeb.LoginLive do
  @moduledoc "Editorial sign-in. OIDC when configured; local email when DEV_AUTH is on."
  use FirstmatePortWeb, :live_view

  import Phoenix.Controller, only: [get_csrf_token: 0]

  @impl true
  def mount(_params, _session, socket) do
    oidc? = oidc_configured?()
    dev? = Application.get_env(:firstmate_port, :dev_auth, false)

    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:oidc?, oidc?)
     |> assign(:dev?, dev?)
     |> assign(:email, "")
     |> assign(:error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <section class="auth-hero">
        <p class="brand-mark">firstmate port</p>
        <h1>The companion for a captain and crew.</h1>
        <p class="lede">
          Review diagrams, PRs, issues, farm rolls, and no-mistakes runs in one place.
        </p>
      </section>

      <section class="auth-panel" aria-labelledby="sign-in-heading">
        <h2 id="sign-in-heading">Sign in</h2>

        <%= if @oidc? do %>
          <.link href={~p"/auth/oidc"} class="btn btn-primary auth-cta">
            Continue with identity provider
          </.link>
        <% end %>

        <%= if @dev? do %>
          <form action={~p"/auth/dev"} method="post" class="auth-form">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <label for="email">Email</label>
            <input
              id="email"
              type="email"
              name="email"
              value={@email}
              autocomplete="username"
              required
            />
            <p class="hint">Local only. Allowed domains come from ALLOWED_EMAIL_DOMAIN.</p>
            <button type="submit" class="btn btn-primary">Enter the port</button>
          </form>
        <% end %>

        <%= if not @oidc? and not @dev? do %>
          <p class="empty-copy" role="status">
            Sign-in is not configured. Set OIDC_ISSUER and OIDC_CLIENT_SECRET, or enable DEV_AUTH for a local compose stack.
          </p>
        <% end %>
      </section>
    </Layouts.auth>
    """
  end

  defp oidc_configured? do
    cfg = Application.get_env(:firstmate_port, FirstmatePortWeb.Auth.OIDCStrategy) || []
    discovery = cfg[:discovery_url] || Application.get_env(:firstmate_port, :oidc_issuer)
    secret = cfg[:client_secret]
    is_binary(discovery) and discovery != "" and is_binary(secret) and secret != ""
  end
end
