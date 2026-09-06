defmodule FirstmatePortWeb.SessionsLive do
  @moduledoc """
  Which `fm-steer` logins can currently act as you, and the button that ends one.

  A device-code grant leaves a long-lived token in a file on some machine. This
  page is where that stops being invisible: every session shows where it was
  approved from and when it was last used, and revoking one takes effect on that
  token's next request rather than whenever it would have expired.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Auth.CliSession

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "sessions")
     |> assign(:error, nil)
     |> load_sessions()}
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    with {:ok, session} <- find(id, socket),
         {:ok, _} <- CliSession.revoke(session, %{}, opts(socket)) do
      {:noreply,
       socket
       |> assign(:error, nil)
       |> put_flash(:info, "Session revoked. That CLI has to sign in again.")
       |> load_sessions()}
    else
      _ -> {:noreply, assign(socket, :error, "That session is no longer here.")}
    end
  end

  defp find(id, socket) do
    case Enum.find(socket.assigns.sessions, &(&1.id == id)) do
      nil -> :error
      session -> {:ok, session}
    end
  end

  defp load_sessions(socket) do
    case CliSession.mine(opts(socket)) do
      {:ok, sessions} -> assign(socket, :sessions, sessions)
      {:error, _} -> socket |> assign(:sessions, []) |> assign(:error, "Could not read sessions.")
    end
  end

  defp opts(socket), do: [actor: socket.assigns.current_user]

  defp state(%{revoked_at: at}) when not is_nil(at), do: "revoked"

  defp state(%{expires_at: at}) do
    if DateTime.compare(DateTime.utc_now(), at) == :gt, do: "expired", else: "active"
  end

  defp used(%{last_used_at: nil}), do: "never used"
  defp used(%{last_used_at: at}), do: "last used #{at}"

  defp agent(%{user_agent: ""}), do: "unknown client"
  defp agent(%{user_agent: agent}), do: agent

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Sessions</h1>
      </header>

      <p class="meta">
        Every <span class="kind">fm-steer auth login</span>
        that was approved as {@current_user.email}. Revoking one stops that token on its next
        request.
      </p>

      <p :if={@error} class="empty-copy" role="alert">{@error}</p>

      <section class="plate">
        <h2>Command-line sessions</h2>
        <p :if={@sessions == []} class="empty-state">
          No CLI has signed in yet. Run <span class="kind">fm-steer auth login</span>
          and approve the code.
        </p>
        <ol class="rows">
          <li :for={session <- @sessions} id={"session-" <> session.id}>
            <span>
              <span class="kind">{state(session)}</span>
              {agent(session)}
              <span class="meta">{session.instance}</span>
              <span class="meta">approved {session.inserted_at} - {used(session)}</span>
            </span>
            <span>
              <time class="meta">expires {session.expires_at}</time>
              <button
                :if={is_nil(session.revoked_at)}
                type="button"
                class="btn btn-quiet"
                phx-click="revoke"
                phx-value-id={session.id}
                data-confirm="Revoke this session? That CLI will have to sign in again."
              >
                Revoke
              </button>
            </span>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
