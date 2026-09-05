defmodule FirstmatePortWeb.Router do
  use FirstmatePortWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FirstmatePortWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug FirstmatePortWeb.Plugs.LoadActor
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug FirstmatePortWeb.Plugs.LoadActor
  end

  pipeline :api_write do
    plug :accepts, ["json"]
    plug FirstmatePortWeb.Plugs.LoadActor
    plug FirstmatePortWeb.Plugs.RequireAgent
  end

  pipeline :cli do
    plug :accepts, ["json"]
    plug FirstmatePortWeb.Plugs.LoadActor
    plug FirstmatePortWeb.Plugs.RequireUser
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug FirstmatePortWeb.Plugs.LoadActor
    plug FirstmatePortWeb.Plugs.RequireAgent
    plug :put_mcp_actor
  end

  pipeline :discord_http do
    plug :accepts, ["json"]
  end

  scope "/.well-known", FirstmatePortWeb do
    pipe_through :api

    get "/oauth-protected-resource", OAuthMetadataController, :protected_resource
    get "/oauth-protected-resource/mcp", OAuthMetadataController, :protected_resource
    get "/oauth-authorization-server", OAuthMetadataController, :authorization_server
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", AshAi.Mcp.Router,
      otp_app: :firstmate_port,
      tools: FirstmatePortWeb.Mcp.v1_tools(),
      protocol_version_statement: "2025-03-26",
      mcp_name: "firstmate",
      instructions: FirstmatePortWeb.Mcp.instructions()
  end

  scope "/api", FirstmatePortWeb.Api do
    pipe_through :api

    get "/diagrams", IngestController, :list_diagrams
    get "/progress", IngestController, :list_progress
    get "/rolls", IngestController, :list_rolls
    get "/no-mistakes", IngestController, :list_no_mistakes
  end

  scope "/api/cli", FirstmatePortWeb do
    pipe_through :api

    post "/auth/device", CliAuthController, :device
    post "/auth/token", CliAuthController, :token
  end

  scope "/api", FirstmatePortWeb.Api do
    pipe_through :cli

    get "/credentials", CredentialsController, :index
    get "/credentials/slots", CredentialsController, :slots
    post "/credentials", CredentialsController, :create
    put "/credentials/:provider/:key", CredentialsController, :put
    patch "/credentials/:provider/:key", CredentialsController, :patch
    delete "/credentials/:provider/:key", CredentialsController, :delete
  end

  scope "/api/cli", FirstmatePortWeb do
    pipe_through :cli

    post "/inbox/put", CliInboxController, :put
    post "/inbox/next", CliInboxController, :next
    post "/inbox/ack", CliInboxController, :ack
    get "/inbox", CliInboxController, :list
  end

  scope "/api", FirstmatePortWeb.Api do
    pipe_through :api_write

    post "/diagrams", IngestController, :create_diagram
    post "/progress", IngestController, :create_progress
    post "/rolls", IngestController, :create_roll
    post "/no-mistakes", IngestController, :create_no_mistakes
  end

  scope "/", FirstmatePortWeb do
    pipe_through :browser

    live "/login", LoginLive
    get "/auth/oidc", AuthController, :request
    get "/auth/oidc/callback", AuthController, :callback
    post "/auth/dev", AuthController, :dev_login
    get "/auth/logout", AuthController, :logout
    get "/healthz", PageController, :healthz
    get "/d/:id/card.png", DiagramHTMLController, :card
    get "/d/:id", DiagramHTMLController, :show
  end

  scope "/", FirstmatePortWeb do
    pipe_through :discord_http

    post "/interactions", DiscordInteractionsController, :create
  end

  scope "/", FirstmatePortWeb do
    pipe_through [:browser, FirstmatePortWeb.Plugs.RequireUser]

    live "/login/device", DeviceLive
    live "/", PortalLive
    live "/queues", QueuesLive
    live "/prs", BoardLive
    live "/issues", BoardLive
    live "/rolls/:id", RollLive
    live "/no-mistakes", NoMistakesLive
    live "/settings/credentials", CredentialsLive
  end

  if Application.compile_env(:firstmate_port, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FirstmatePortWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  defp put_mcp_actor(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn

      user ->
        conn
        |> Ash.PlugHelpers.set_actor(user)
        |> Ash.PlugHelpers.set_tenant(FirstmatePort.Tenancy.slug(user))
    end
  end
end
