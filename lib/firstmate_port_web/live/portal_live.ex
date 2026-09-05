defmodule FirstmatePortWeb.PortalLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.BuildTracking

  alias FirstmatePort.Portal.{
    BuildBuddyInvocation,
    Diagram,
    DockerBuild,
    NoMistakesRun,
    ProgressItem,
    Roll
  }

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    opts = FirstmatePort.Tenancy.opts(actor)
    {:ok, diagrams} = Diagram.list(opts)
    {:ok, progress} = ProgressItem.list(opts)
    {:ok, nm} = NoMistakesRun.list(opts)

    show_kubernetes = BuildTracking.kubernetes_enabled?()
    show_docker = BuildTracking.docker_enabled?()
    show_buildbuddy = BuildTracking.buildbuddy_enabled?()

    {:ok, rolls} = if show_kubernetes, do: Roll.list(opts), else: {:ok, []}
    {:ok, docker_builds} = if show_docker, do: DockerBuild.list(opts), else: {:ok, []}

    {:ok, invocations} =
      if show_buildbuddy, do: BuildBuddyInvocation.list(opts), else: {:ok, []}

    {:ok,
     socket
     |> assign(:page_title, "firstmate")
     |> assign(:diagrams, diagrams)
     |> assign(:progress, progress)
     |> assign(:rolls, rolls)
     |> assign(:docker_builds, docker_builds)
     |> assign(:invocations, invocations)
     |> assign(:show_kubernetes, show_kubernetes)
     |> assign(:show_docker, show_docker)
     |> assign(:show_buildbuddy, show_buildbuddy)
     |> assign(:no_mistakes, nm)
     |> assign(:filter, "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        nil -> "all"
        "rolls" -> "kubernetes"
        other -> other
      end

    {:noreply, assign(socket, :filter, tab)}
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
          <.link
            :if={@show_kubernetes}
            patch={~p"/?tab=kubernetes"}
            aria-current={@filter == "kubernetes" && "page"}
          >
            Kubernetes
          </.link>
          <.link
            :if={@show_docker}
            patch={~p"/?tab=docker"}
            aria-current={@filter == "docker" && "page"}
          >
            Docker
          </.link>
          <.link
            :if={@show_buildbuddy}
            patch={~p"/?tab=buildbuddy"}
            aria-current={@filter == "buildbuddy" && "page"}
          >
            BuildBuddy
          </.link>
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

      <section :if={@show_kubernetes and @filter in ["all", "kubernetes"]} class="plate">
        <h2>Kubernetes</h2>
        <p :if={@rolls == []} class="empty-state">No Kubernetes rolls recorded.</p>
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

      <section :if={@show_docker and @filter in ["all", "docker"]} class="plate">
        <h2>Docker</h2>
        <p :if={@docker_builds == []} class="empty-state">No Docker builds recorded.</p>
        <ol class="rows">
          <li :for={b <- @docker_builds}>
            <.link href={~p"/docker-builds/#{b.id}"}>{b.repository}:{b.tag} {b.status}</.link>
            <span class="meta">
              {b.digest}
              <a :if={b.pr_url != ""} href={b.pr_url}>{b.pr_url}</a>
            </span>
          </li>
        </ol>
      </section>

      <section :if={@show_buildbuddy and @filter in ["all", "buildbuddy"]} class="plate">
        <h2>BuildBuddy</h2>
        <p :if={@invocations == []} class="empty-state">No BuildBuddy invocations recorded.</p>
        <ol class="rows">
          <li :for={i <- @invocations}>
            <.link href={~p"/buildbuddy-invocations/#{i.id}"}>{i.invocation_id} {i.status}</.link>
            <span class="meta">
              {i.branch}
              <a :if={i.buildbuddy_url != ""} href={i.buildbuddy_url}>invocation</a>
            </span>
          </li>
        </ol>
      </section>

      <section :if={@filter in ["all", "no-mistakes"]} class="plate">
        <h2>no-mistakes</h2>
        <p :if={@no_mistakes == []} class="empty-state">
          No pipeline runs posted yet.
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
