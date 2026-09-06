defmodule FirstmatePortWeb.PortalLive do
  @moduledoc """
  The home fleet log.

  Progress is a preview here, not an archive: the newest
  `ProgressItem.preview_size/0` rows, fetched with a server-side limit, and a
  "see all" link to `/progress` once there are more. The full list is never
  rendered and then hidden.
  """
  use FirstmatePortWeb, :live_view

  import FirstmatePortWeb.ProgressComponents

  alias FirstmatePort.BuildTracking

  alias FirstmatePort.Portal.{
    BuildBuddyInvocation,
    Diagram,
    DockerBuild,
    NoMistakesRun,
    ProgressItem,
    ProgressProjection,
    Roll
  }

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    opts = FirstmatePort.Tenancy.opts(actor)
    {:ok, diagrams} = Diagram.list(opts)
    {:ok, progress} = ProgressItem.list_recent(opts)
    {:ok, projections} = ProgressProjection.load(progress, opts)
    {:ok, progress_total} = Ash.count(ProgressItem, opts)
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
     |> assign(:preview_size, ProgressItem.preview_size())
     |> assign(:diagrams, diagrams)
     |> assign(:progress, projections)
     |> assign(:progress_total, progress_total)
     |> assign(:detail, nil)
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
    opts = FirstmatePort.Tenancy.opts(socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:filter, params["tab"] || "all")
     |> assign(:detail, load_detail(params["item"], ProgressProjection.parse_offset(params["event_offset"]), opts))}
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
        <.progress_table
          :if={@progress != []}
          id="progress-preview"
          projections={@progress}
          detail_path={&detail_path(@filter, &1)}
        />
        <p class="see-all">
          <.link navigate={~p"/progress"}>
            See all {@progress_total} PRs, issues, and achievements
          </.link>
        </p>
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

      <.progress_details
        projection={@detail}
        close_path={close_path(@filter)}
        event_path={fn offset -> detail_path(@filter, @detail.item.id) <> "&event_offset=#{offset}" end}
      />
    </Layouts.app>
    """
  end

  defp detail_path(filter, id), do: ~p"/?tab=#{filter}&item=#{id}"
  defp close_path(filter), do: ~p"/?tab=#{filter}"

  # The preview only holds 20 rows, so a deep link to an older row still has to
  # be fetched by id.
  defp load_detail(nil, _offset, _opts), do: nil
  defp load_detail("", _offset, _opts), do: nil

  defp load_detail(id, offset, opts) do
    with {:ok, item} when not is_nil(item) <- ProgressItem.get_by_id(id, opts),
         {:ok, projection} <- ProgressProjection.load_one(item, opts, 100, offset) do
      projection
    else
      _ -> nil
    end
  end
end
