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
  Ship's-wheel mark. Strokes use `currentColor` so the mark follows the
  surrounding text color (ink in light mode, paper in dark mode).
  """
  def wheel_mark(assigns) do
    ~H"""
    <svg
      viewBox="0 0 48 48"
      fill="none"
      stroke="currentColor"
      stroke-linecap="round"
      aria-hidden="true"
      focusable="false"
      class="brand-wheel"
    >
      <circle cx="24" cy="24" r="12" stroke-width="3" />
      <path
        d="M24 4v16M24 28v16M4 24h16M28 24h16M9.9 9.9l11.3 11.3M26.8 26.8l11.3 11.3M38.1 9.9L26.8 21.2M21.2 26.8L9.9 38.1"
        stroke-width="2.5"
      />
      <circle cx="24" cy="24" r="4" stroke-width="2.5" />
      <circle cx="24" cy="24" r="1.4" fill="currentColor" stroke="none" />
    </svg>
    """
  end

  attr :flash, :map, required: true
  attr :current_user, :any, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <header class="topbar">
        <.link navigate={~p"/"} class="brand"><.wheel_mark />firstmate port</.link>
        <nav class="nav" aria-label="Primary">
          <.link navigate={~p"/"}>Log</.link>
          <.link navigate={~p"/prs"}>PRs</.link>
          <.link navigate={~p"/issues"}>Issues</.link>
          <.link navigate={~p"/no-mistakes"}>no-mistakes</.link>
          <.link navigate={~p"/queues"}>Queues</.link>
          <.link navigate={~p"/settings/credentials"}>Credentials</.link>
        </nav>
        <div class="topbar-end">
          <.theme_toggle />
          <span :if={@current_user} class="who">{@current_user.email}</span>
          <.link :if={@current_user} href={~p"/auth/logout"} class="quiet">Sign out</.link>
        </div>
      </header>
      <main class="main">
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="auth-shell">
      <header class="auth-top">
        <.link href={~p"/login"} class="brand"><.wheel_mark />firstmate port</.link>
        <.theme_toggle />
      </header>
      <.flash_group flash={@flash} />
      <div class="auth-main">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
