defmodule FirstmatePortWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FirstmatePortWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="theme-toggle" role="group" aria-label="Color theme">
      <button type="button" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="system">
        System
      </button>
      <button type="button" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light">
        Light
      </button>
      <button type="button" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark">
        Dark
      </button>
    </div>
    """
  end

  @doc """
  Ship's-wheel mark from the captain's SVG. Served as two static files so
  the mark renders black in light mode and white in dark mode.
  """
  def wheel_mark(assigns) do
    ~H"""
    <span class="brand-wheel" aria-hidden="true">
      <img
        src={~p"/images/steering-wheel-black.svg"}
        alt=""
        width="22"
        height="22"
        class="brand-wheel-light"
      />
      <img
        src={~p"/images/steering-wheel-white.svg"}
        alt=""
        width="22"
        height="22"
        class="brand-wheel-dark"
      />
    </span>
    """
  end

  @doc """
  Gravatar URL for an account email, with an identicon fallback when the
  address has no Gravatar image.
  """
  def avatar_url(email) do
    hash =
      email
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    "https://www.gravatar.com/avatar/#{hash}?s=64&d=identicon"
  end

  attr :current_user, :any, required: true

  def account_menu(assigns) do
    ~H"""
    <details class="account-menu">
      <summary aria-label={"Account: #{@current_user.email}"} title={@current_user.email}>
        <img
          src={avatar_url(@current_user.email)}
          alt=""
          width="30"
          height="30"
          class="account-avatar"
        />
      </summary>
      <div class="account-panel">
        <p class="account-email">{@current_user.email}</p>
        <p class="account-section-label">Color theme</p>
        <.theme_toggle />
        <.link href={~p"/auth/logout"} class="btn btn-quiet account-signout">Sign out</.link>
      </div>
    </details>
    """
  end

  attr :flash, :map, required: true
  attr :current_user, :any, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <header class="topbar">
        <.link navigate={~p"/"} class="brand">
          <.wheel_mark /><span class="brand-text">firstmate port</span>
        </.link>
        <nav class="nav" aria-label="Primary">
          <.link navigate={~p"/"}>Log</.link>
          <.link navigate={~p"/search"}>Search</.link>
          <.link navigate={~p"/inbox"}>Inbox</.link>
          <.link navigate={~p"/prs"}>PRs</.link>
          <.link navigate={~p"/issues"}>Issues</.link>
          <.link navigate={~p"/no-mistakes"}>no-mistakes</.link>
          <.link navigate={~p"/queues"}>Queues</.link>
          <.link navigate={~p"/usage"}>Usage</.link>
          <.link navigate={~p"/steer"}>fm-steer</.link>
          <.link navigate={~p"/settings/credentials"}>Credentials</.link>
          <.link navigate={~p"/settings/sessions"}>Sessions</.link>
        </nav>
        <div class="topbar-end">
          <.account_menu :if={@current_user} current_user={@current_user} />
          <.theme_toggle :if={is_nil(@current_user)} />
        </div>
      </header>
      <main class="main">
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
      <.site_footer />
    </div>
    """
  end

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="auth-shell">
      <header class="auth-top">
        <.link href={~p"/login"} class="brand">
          <.wheel_mark /><span class="brand-text">firstmate port</span>
        </.link>
        <.theme_toggle />
      </header>
      <.flash_group flash={@flash} />
      <div class="auth-main">
        {render_slot(@inner_block)}
      </div>
      <.site_footer class="auth-footer" />
    </div>
    """
  end

  @doc """
  Chrome for the pages a signed-out visitor is allowed to read: the terms and
  privacy pages Discord's Developer Portal links to.

  Deliberately not `auth/1`. That layout is a two-column sign-in composition
  with a fixed-position header; a legal document wants one readable column and
  ordinary page flow.

  No flash and no theme toggle: these pages run outside a LiveView, where a
  `phx-click` binding is inert, and there is no session to carry a flash. The
  reader's stored theme still applies — the root layout reads it before paint.
  """
  attr :page_title, :string, required: true
  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <div class="shell">
      <header class="topbar">
        <.link href={~p"/"} class="brand">firstmate port</.link>
      </header>
      <main class="main">
        <article class="legal">
          <h1>{@page_title}</h1>
          {render_slot(@inner_block)}
        </article>
      </main>
      <.site_footer />
    </div>
    """
  end

  @doc """
  Footer carrying the public legal links.

  Discord's Developer Portal wants a Terms of Service URL and a Privacy Policy
  URL, and both have to stay reachable for as long as the app is installed. The
  footer is what keeps them discoverable from the product itself rather than
  only from a form field in Discord's dashboard.
  """
  attr :class, :string, default: nil

  def site_footer(assigns) do
    ~H"""
    <footer class={["site-footer", @class]}>
      <nav aria-label="Legal">
        <.link href={~p"/terms"}>Terms</.link>
        <.link href={~p"/privacy"}>Privacy</.link>
      </nav>
    </footer>
    """
  end
end
