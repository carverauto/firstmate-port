defmodule FirstmatePortWeb.PortalLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.{Diagram, NoMistakesRun, ProgressItem, Roll}

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    opts = FirstmatePort.Tenancy.opts(actor)
    {:ok, diagrams} = Diagram.list(opts)
    {:ok, progress} = ProgressItem.list(opts)
    {:ok, rolls} = Roll.list(opts)
    {:ok, nm} = NoMistakesRun.list(opts)

    {:ok,
     socket
     |> assign(:page_title, "firstmate")
     |> assign(:diagrams, diagrams)
     |> assign(:progress, progress)
     |> assign(:rolls, rolls)
     |> assign(:no_mistakes, nm)
     |> assign(:filter, "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :filter, params["tab"] || "all")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Fleet log</h1>
        <nav class="nav" aria-label="Log filters">
          <.link patch={~p"/?tab=all"} aria-current={@filter == "all" && "page"}>All</.link>
          <.link patch={~p"/?tab=diagrams"} aria-current={@filter == "diagrams" && "page"}>
            Diagrams
          </.link>
          <.link patch={~p"/?tab=progress"} aria-current={@filter == "progress" && "page"}>
            Progress
          </.link>
          <.link patch={~p"/?tab=rolls"} aria-current={@filter == "rolls" && "page"}>Rolls</.link>
          <.link patch={~p"/?tab=no-mistakes"} aria-current={@filter == "no-mistakes" && "page"}>
            no-mistakes
          </.link>
        </nav>
      </header>

      <section :if={@filter in ["all", "diagrams"]} class="plate">
        <h2>Diagrams</h2>
        <p :if={@diagrams == []} class="empty-state">
          No diagrams yet. Agents upload HTML via MCP or POST /api/diagrams.
        </p>
        <ol class="rows">
          <li :for={d <- @diagrams}>
            <.link href={~p"/d/#{d.id}"}>{d.title}</.link>
            <span class="meta">{d.id}</span>
          </li>
        </ol>
      </section>

      <section :if={@filter in ["all", "progress"]} class="plate">
        <h2>Progress</h2>
        <p :if={@progress == []} class="empty-state">No PRs, issues, or achievements recorded.</p>
        <ol class="rows">
          <li :for={p <- @progress} id={p.id}>
            <span>
              <span class="kind">{p.kind}</span>
              {p.title}
            </span>
            <a :if={p.url != ""} href={p.url}>{p.url}</a>
          </li>
        </ol>
      </section>

      <section :if={@filter in ["all", "rolls"]} class="plate">
        <h2>Farm / demo rolls</h2>
        <p :if={@rolls == []} class="empty-state">No image builds or helm rolls recorded.</p>
        <ol class="rows">
          <li :for={r <- @rolls}>
            <.link href={~p"/rolls/#{r.id}"}>{r.cluster} {r.status} {r.image_tag}</.link>
            <span class="meta">
              {r.namespace}
              <a :if={r.pr_url != ""} href={r.pr_url}>{r.pr_url}</a>
            </span>
          </li>
        </ol>
      </section>

      <section :if={@filter in ["all", "no-mistakes"]} class="plate">
        <h2>no-mistakes</h2>
        <p :if={@no_mistakes == []} class="empty-state">
          No pipeline runs posted. Firstmate keeps the daemon on the captain Mac.
        </p>
        <ol class="rows">
          <li :for={n <- @no_mistakes} id={n.id}>
            <span>
              <span class="kind">{n.outcome || n.step}</span>
              {n.branch} {n.run_id}
            </span>
            <a :if={n.pr_url != ""} href={n.pr_url}>{n.pr_url}</a>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
