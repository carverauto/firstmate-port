defmodule FirstmatePortWeb.QueuesLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      tenant = FirstmatePort.Tenancy.slug(socket.assigns.current_user)

      Phoenix.PubSub.subscribe(
        FirstmatePort.PubSub,
        FirstmatePort.NATS.QueueListener.topic(tenant)
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "queues")
     |> assign(:connected, FirstmatePort.NATS.Connection.connected?())
     |> assign(:events, [])}
  end

  @impl true
  def handle_info({:nats_event, event}, socket) do
    {:noreply, assign(socket, :events, Enum.take([event | socket.assigns.events], 100))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Queues</h1>
        <p class="meta">{if @connected, do: "NATS connected", else: "NATS not connected"}</p>
      </header>
      <p :if={@events == []} class="empty-state">
        No queue traffic yet. Durable consumers watch &lt;tenant&gt;.steer.&gt; and &lt;tenant&gt;.discord.inbound.
      </p>
      <ol class="rows">
        <li :for={e <- @events}>
          <span>
            <span class="kind">{e.subject}</span>
            <time>{e.at}</time>
          </span>
          <pre>{e.body}</pre>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
