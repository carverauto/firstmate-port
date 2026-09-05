defmodule FirstmatePortWeb.LoginLive do
  @moduledoc """
  Editorial sign-in.

  Offers whatever is actually available: the local account when local auth is on,
  an identity provider when `FirstmatePort.Auth.OIDC.ready?/1` permits it, and an
  honest message when neither is. A configured-but-unreachable provider is called
  out as unreachable rather than unconfigured, because those need different fixes.
  """
  use FirstmatePortWeb, :live_view

  import Phoenix.Controller, only: [get_csrf_token: 0]

  @impl true
  def mount(_params, _session, socket) do
    oidc = FirstmatePort.Auth.OIDC.status()
    local? = Application.get_env(:firstmate_port, :local_auth, false)

    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:oidc, oidc)
     |> assign(:oidc?, oidc == :ready)
     |> assign(:local?, local?)
     |> assign(:email, "")
     |> assign(:error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <section class="auth-hero">
        <h1>The companion for a captain and crew.</h1>
        <p class="lede">
          Review diagrams, PRs, issues, image builds, Kubernetes and Docker deploys,
          and no-mistakes runs in one place.
        </p>
        <ul class="auth-points">
          <li>One log for diagrams, progress, and pipeline runs</li>
          <li>Sign in with your identity provider</li>
          <li>Local-dev sign-in for development</li>
        </ul>
      </section>

      <section class="auth-card" aria-labelledby="sign-in-heading">
        <h2 id="sign-in-heading">Sign in</h2>

        <%= if @oidc? do %>
          <.link href={~p"/auth/oidc"} class="btn btn-primary auth-cta">
            Continue with identity provider
          </.link>
        <% end %>

        <%= if @local? do %>
          <form action={~p"/auth/local"} method="post" class="auth-form">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <label for="email">Email</label>
            <input
              id="email"
              type="email"
              name="email"
              value={@email}
              autocomplete="username"
              placeholder="you@example.com"
              required
            />
            <label for="password">Password</label>
            <input
              id="password"
              type="password"
              name="password"
              autocomplete="current-password"
              required
            />
            <p class="hint">
              For Docker Compose, find generated first-run credentials in <code>docker compose logs portal</code>.
              For Kubernetes, read the bootstrap admin secret, <code>firstmate-admin</code>.
            </p>
            <button type="submit" class="btn btn-primary">Enter the port</button>
          </form>
        <% end %>

        <%= if @oidc == :unavailable do %>
          <p class="empty-copy" role="status">
            Your identity provider is not reachable right now.
          </p>
        <% end %>

        <%= if @oidc == :disabled and not @local? do %>
          <p class="empty-copy" role="status">
            Sign-in is not configured. Set LOCAL_AUTH=true for the local account, or set OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET for an identity provider.
          </p>
        <% end %>
      </section>
    </Layouts.auth>
    """
  end
end
