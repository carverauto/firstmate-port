defmodule FirstmatePortWeb.Router do
  use FirstmatePortWeb, :router

  alias FirstmatePortWeb.Plugs.RateLimit
  alias FirstmatePortWeb.Plugs.SecurityHeaders

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FirstmatePortWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug SecurityHeaders, csp: :browser
    plug FirstmatePortWeb.Plugs.LoadActor
  end

  # Stored Archify artifacts are whole HTML documents with their own inline
  # script and style, so `/d/:id` cannot run under the nonced portal policy.
  # Everything else about the pipeline matches :browser.
  pipeline :diagram do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FirstmatePortWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug SecurityHeaders, csp: :embed
    plug FirstmatePortWeb.Plugs.LoadActor
  end

  # Static legal documents. No session, no CSRF token, no actor lookup: nothing
  # on these pages reads or writes any of them, and a page that sets no cookie
  # is one a shared cache in front of the app can safely hold. `:browser` would
  # attach a session cookie to every response, which makes `cache-control:
  # public` a way to hand one reader's cookie to another.
  pipeline :public_page do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {FirstmatePortWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug SecurityHeaders, csp: :browser
  end

  # The limiter runs before `LoadActor` here because this bucket keys on the
  # address alone: a flood of requests carrying a bogus bearer token should be
  # refused without first asking the database to look each one up. The
  # pipelines below key on the actor too, so their limiter has to come after.
  pipeline :api do
    plug :accepts, ["json"]
    plug SecurityHeaders, csp: :api
    plug RateLimit, bucket: :api_default, response_mode: :json
    plug FirstmatePortWeb.Plugs.LoadActor
  end

  # RFC 8628 device-code endpoints. Their own pipeline so the tight per-endpoint
  # buckets declared on `CliAuthController` are the only limit that applies —
  # `fm-steer` polls `/auth/token` on a timer and must not also spend the shared
  # read budget while it waits.
  pipeline :cli_auth do
    plug :accepts, ["json"]
    plug SecurityHeaders, csp: :api
    plug FirstmatePortWeb.Plugs.LoadActor
  end

  pipeline :api_write do
    plug :accepts, ["json"]
    plug SecurityHeaders, csp: :api
    plug FirstmatePortWeb.Plugs.LoadActor
    plug RateLimit, bucket: :api_write, subject: :ip_and_actor, response_mode: :json
    plug FirstmatePortWeb.Plugs.RequireAgent
  end

  pipeline :cli do
    plug :accepts, ["json"]
    plug SecurityHeaders, csp: :api
    plug FirstmatePortWeb.Plugs.LoadActor
    plug RateLimit, bucket: :api_default, subject: :ip_and_actor, response_mode: :json
    plug FirstmatePortWeb.Plugs.RequireUser
  end

  pipeline :authed do
    plug SecurityHeaders, csp: :api
    plug :accepts, ["json"]
    plug FirstmatePortWeb.Plugs.LoadActor
    plug RateLimit, bucket: :api_write, subject: :ip_and_actor, response_mode: :json
    plug FirstmatePortWeb.Plugs.RequireActor
  end

  # Signed in is the bar here, agent or human: the resource policies decide what
  # each may actually do, and the captain uploading an Archify diagram from
  # `fm-steer` should not need a second, agent-shaped credential.
  pipeline :mcp do
    plug :accepts, ["json"]
    plug SecurityHeaders, csp: :api
    plug FirstmatePortWeb.Plugs.LoadActor
    plug RateLimit, bucket: :mcp, subject: :ip_and_actor, response_mode: :json
    plug FirstmatePortWeb.Plugs.RequireUser
    plug :put_mcp_actor
  end

  # Discord fans interactions out from many addresses and expects an answer
  # inside 3s, so this bucket is a runaway-loop guard, not an access control.
  # The Ed25519 signature check in the controller is the access control.
  pipeline :discord_http do
    plug :accepts, ["json"]
    plug SecurityHeaders, csp: :api
    plug RateLimit, bucket: :discord_interactions, response_mode: :json
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
    get "/progress/:id", IngestController, :show_progress
    get "/rolls", IngestController, :list_rolls
    get "/docker-builds", IngestController, :list_docker_builds
    get "/buildbuddy-invocations", IngestController, :list_buildbuddy_invocations
    get "/no-mistakes", IngestController, :list_no_mistakes
    get "/fleet/search", FleetController, :search
    get "/build-events", BuildEventsController, :index
    get "/build-runs", BuildEventsController, :runs
  end

  scope "/api/cli", FirstmatePortWeb do
    pipe_through :cli_auth

    post "/auth/device", CliAuthController, :device
    post "/auth/token", CliAuthController, :token
  end

  scope "/api", FirstmatePortWeb.Api do
    pipe_through :cli

    get "/queues", QueueController, :index
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

  scope "/api", FirstmatePortWeb do
    pipe_through :authed

    get "/usage", UsageController, :index
    post "/usage", UsageController, :create
    post "/route", RouteController, :create
  end

  # Asking the captain a question is a write by whoever is signed in - firstmate
  # as an agent, or the captain's own device token. The answer never comes back
  # here; it arrives on POST /interactions, signed by Discord.
  scope "/api/captain", FirstmatePortWeb.Api do
    pipe_through :authed

    get "/calls", CaptainCallController, :index
    get "/calls/:id", CaptainCallController, :show
    post "/calls", CaptainCallController, :create
  end

  scope "/api", FirstmatePortWeb.Api do
    pipe_through :cli

    post "/diagrams", IngestController, :create_diagram
  end

  scope "/api", FirstmatePortWeb.Api do
    pipe_through :api_write

    post "/queues", QueueController, :create
    post "/progress", IngestController, :create_progress
    post "/progress/events", IngestController, :create_progress_event
    post "/rolls", IngestController, :create_roll
    post "/docker-builds", IngestController, :create_docker_build
    post "/buildbuddy-invocations", IngestController, :create_buildbuddy_invocation
    post "/no-mistakes", IngestController, :create_no_mistakes
    post "/fleet/sync", FleetController, :sync
    post "/build-events", BuildEventsController, :create
  end

  scope "/", FirstmatePortWeb do
    pipe_through :browser

    live "/login", LoginLive
    get "/auth/oidc", AuthController, :request
    get "/auth/oidc/callback", AuthController, :callback
    post "/auth/local", AuthController, :local_login
    get "/auth/logout", AuthController, :logout
    get "/healthz", PageController, :healthz
    get "/steer", SteerController, :landing
    get "/steer/docs", SteerController, :docs
    get "/steer/docs/fm-steer", SteerController, :doc_fm_steer
    get "/steer/docs/routing", SteerController, :doc_routing
    get "/steer/docs/usage", SteerController, :doc_usage
  end

  # Public on purpose: Discord's Developer Portal needs both URLs to answer a
  # signed-out GET before an application can be distributed.
  scope "/", FirstmatePortWeb do
    pipe_through :public_page

    get "/terms", LegalController, :terms
    get "/privacy", LegalController, :privacy
  end

  scope "/", FirstmatePortWeb do
    pipe_through :diagram

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
    live "/search", SearchLive
    live "/progress", ProgressLive
    live "/inbox", InboxLive
    live "/queues", QueuesLive
    live "/usage", UsageLive
    live "/prs", BoardLive
    live "/issues", BoardLive
    live "/rolls/:id", RollLive
    live "/docker-builds/:id", DockerBuildLive
    live "/buildbuddy-invocations/:id", BuildBuddyLive
    live "/no-mistakes", NoMistakesLive
    live "/settings/credentials", CredentialsLive
    live "/settings/sessions", SessionsLive
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
