defmodule FirstmatePortWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Response headers for the public hostname: HSTS, Permissions-Policy, and a
  per-request nonced Content-Security-Policy.

  Phoenix's `put_secure_browser_headers/2` already covers `x-frame-options`,
  `x-content-type-options`, `referrer-policy` and friends. This plug adds what
  it does not, following `ServiceRadarWebNGWeb.Plugs.SecurityHeaders`, with one
  difference: the CSP is built here per request rather than handed in as a
  static string, because the portal's root layout runs an inline script to
  apply the stored colour theme before first paint. That script gets a
  freshly generated nonce, so `script-src` never needs `'unsafe-inline'` and
  the policy can be flipped to enforcing without breaking the page.

  ## Options

    * `:csp` — required policy to serve:
      * `:browser` — the portal UI. Same-origin everything, nonced inline
        script, websockets for LiveView.
      * `:embed` — stored Archify diagram HTML served at `/d/:id`. Those
        artifacts are self-contained pages with their own inline script and
        style, so this policy allows inline while still forbidding framing,
        plugins, form posts and cross-origin loads.
      * `:api` — JSON endpoints. Denies everything; a JSON response has no
        business loading a subresource.
    * `:csp_mode` — `:report_only` (default) or `:enforce`. Report-only applies
      to the resource directives, the ones that can break a page. The framing
      and form-action baseline is enforced in both modes: browsers ignore
      `frame-ancestors` in a report-only policy, so demoting it would leave the
      app *less* protected than Phoenix's own defaults.
    * `:csp_report_uri` — appended as `report-uri` when set.
    * `:hsts_max_age` — seconds, default two years. Only sent on HTTPS.
    * `:hsts_include_subdomains` — default `true`.
    * `:hsts_preload` — default `false`. Only turn this on once the apex
      domain is actually enrolled in the preload list; it is hard to undo.
    * `:permissions_policy` — full header value.

  Runtime config overrides every option, so CSP can be flipped without a
  redeploy:

      config :firstmate_port, FirstmatePortWeb.Plugs.SecurityHeaders,
        csp_mode: :enforce
  """

  @behaviour Plug

  import Plug.Conn

  @default_permissions_policy "accelerometer=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), serial=(), usb=()"
  # Two years, the value the HSTS preload list requires.
  @default_hsts_max_age 63_072_000

  # Phoenix.LiveReloader injects an iframe, so a dev build that forbids framing
  # outright fills the console with reports for a frame production never serves.
  # `:dev_routes` is the existing marker for a dev build and, unlike `Mix.env/0`,
  # is readable from a release.
  @frame_src if Application.compile_env(:firstmate_port, :dev_routes, false),
               do: "'self'",
               else: "'none'"

  # Directives that cannot break a page that already works, so they are enforced
  # from the first deploy rather than waiting out the report-only soak.
  @baseline "frame-ancestors 'none'; object-src 'none'; base-uri 'self'; form-action 'self'"
  @embed_baseline "frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

  # Archify artifacts are whole standalone pages stored as HTML. Their inline
  # script and style are the diagram, so this policy cannot forbid inline; it
  # restricts off-origin loads and form submission. Same-origin scripts and
  # fetches remain allowed; this policy does not isolate HTML from the session.
  @embed_policy "default-src 'self'; script-src 'self' 'unsafe-inline' blob:; " <>
                  "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " <>
                  "font-src 'self' data:; connect-src 'self'; frame-src 'none'; " <>
                  @embed_baseline

  @api_policy "default-src 'none'; " <> @embed_baseline

  @impl true
  def init(opts) do
    csp = Keyword.get(opts, :csp)

    if csp not in [:browser, :embed, :api] do
      raise ArgumentError,
            "SecurityHeaders :csp is required and must be :browser, :embed or :api (got #{inspect(csp)})"
    end

    opts
  end

  @impl true
  def call(conn, opts) do
    opts = Keyword.merge(opts, Application.get_env(:firstmate_port, __MODULE__) || [])

    conn
    |> put_nonce(Keyword.get(opts, :csp))
    |> register_before_send(&apply_headers(&1, opts))
  end

  @doc """
  The nonce assigned to this request, for `<script nonce={...}>` in a layout.

  Returns `nil` on a conn that never ran this plug, which keeps the root
  layout renderable from error views and tests.
  """
  @spec nonce(map()) :: String.t() | nil
  def nonce(%{csp_nonce: nonce}), do: nonce
  def nonce(_assigns), do: nil

  defp put_nonce(conn, _csp) do
    assign(conn, :csp_nonce, Base.encode64(:crypto.strong_rand_bytes(16)))
  end

  # A conn that has already been sent, or handed to a websocket transport, can
  # no longer take response headers — writing one there raises and turns the
  # request into a 500. There is no document left to protect either way.
  defp apply_headers(%Plug.Conn{state: state} = conn, _opts) when state in [:sent, :upgraded] do
    conn
  end

  defp apply_headers(conn, opts) do
    conn
    |> put_hsts(opts)
    |> put_resp_header(
      "permissions-policy",
      Keyword.get(opts, :permissions_policy, @default_permissions_policy)
    )
    |> put_csp(opts)
  end

  defp put_hsts(conn, opts) do
    if conn.scheme == :https do
      value =
        ["max-age=#{Keyword.get(opts, :hsts_max_age, @default_hsts_max_age)}"]
        |> append_if(Keyword.get(opts, :hsts_include_subdomains, true), "includeSubDomains")
        |> append_if(Keyword.get(opts, :hsts_preload, false), "preload")
        |> Enum.join("; ")

      put_resp_header(conn, "strict-transport-security", value)
    else
      conn
    end
  end

  defp put_csp(conn, opts) do
    {baseline, full} = policies(conn, Keyword.fetch!(opts, :csp))
    report_uri = Keyword.get(opts, :csp_report_uri)
    mode = if baseline == full, do: :enforce, else: Keyword.get(opts, :csp_mode, :report_only)

    case mode do
      :enforce ->
        conn
        |> delete_resp_header("content-security-policy-report-only")
        |> put_resp_header("content-security-policy", append_report_uri(full, report_uri))

      _report_only ->
        # The baseline stays *enforced* even in report-only mode. Phoenix's
        # own `put_secure_browser_headers` ships `frame-ancestors 'self'`,
        # and simply demoting the whole policy to report-only would leave
        # the app less framing-proof than before this plug existed. Browsers
        # also ignore `frame-ancestors` in a report-only policy, so it is
        # only worth anything enforced. What lands in report-only is the
        # part that can actually break a page: the resource directives.
        conn
        |> put_resp_header("content-security-policy", baseline)
        |> put_resp_header(
          "content-security-policy-report-only",
          append_report_uri(full, report_uri)
        )
    end
  end

  # `{always enforced, full policy}`.
  defp policies(conn, :browser), do: {@baseline, browser_policy(conn.assigns[:csp_nonce])}
  defp policies(_conn, :embed), do: {@embed_baseline, @embed_policy}
  # A JSON response has no subresources to break, so there is nothing to soak.
  defp policies(_conn, :api), do: {@api_policy, @api_policy}

  defp browser_policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self'#{nonce_source(nonce)}",
        # Tailwind ships a stylesheet, but LiveView and the topbar progress
        # bar set style attributes from JavaScript.
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self'",
        # LiveView's websocket, plus its longpoll fallback.
        "connect-src 'self' ws: wss:",
        "frame-src #{@frame_src}",
        @baseline
      ],
      "; "
    )
  end

  defp nonce_source(nonce) when is_binary(nonce), do: " 'nonce-#{nonce}'"
  defp nonce_source(_nonce), do: ""

  defp append_report_uri(policy, uri) when is_binary(uri) and uri != "" do
    if String.contains?(policy, "report-uri") do
      policy
    else
      String.trim_trailing(policy, ";") <> "; report-uri " <> uri
    end
  end

  defp append_report_uri(policy, _uri), do: policy

  defp append_if(parts, true, value), do: parts ++ [value]
  defp append_if(parts, _false, _value), do: parts
end
