defmodule FirstmatePortWeb.ProgressLive do
  @moduledoc """
  The standalone progress archive: charts over the whole tenant, then every row
  a page at a time.

  The home fleet log only previews the newest
  #{FirstmatePort.Portal.ProgressItem.preview_size()}; this page pages through
  the rest #{FirstmatePort.Portal.ProgressItem.page_size()} at a time with a
  server-side limit and offset. Table rows and the details modal are the same
  components the home page uses, so the two surfaces cannot drift apart.
  """

  use FirstmatePortWeb, :live_view

  import FirstmatePortWeb.ProgressComponents

  alias FirstmatePort.Portal.{ProgressItem, ProgressProjection}

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "progress")
     |> assign(:projections, [])
     |> assign(:page, 1)
     |> assign(:total, 0)
     |> assign(:total_pages, 1)
     |> assign(:stats, nil)
     |> assign(:capped, false)
     |> assign(:detail, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    opts = FirstmatePort.Tenancy.opts(socket.assigns.current_user)
    limit = ProgressItem.page_size()

    {:ok, total} = Ash.count(ProgressItem, opts)
    total_pages = max(1, ceil_div(total, limit))
    page = params["page"] |> parse_page() |> min(total_pages)

    {:ok, items} = ProgressItem.list_paged(limit, (page - 1) * limit, opts)
    {:ok, projections} = ProgressProjection.load(items, opts)
    {:ok, stats, capped} = ProgressProjection.tenant_stats(opts)

    {:noreply,
     socket
     |> assign(:projections, projections)
     |> assign(:page, page)
     |> assign(:total, total)
     |> assign(:total_pages, total_pages)
     |> assign(:stats, stats)
     |> assign(:capped, capped)
     |> assign(
       :detail,
       load_detail(params["item"], ProgressProjection.parse_offset(params["event_offset"]), opts)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Progress</h1>
        <nav class="nav" aria-label="Progress navigation">
          <.link navigate={~p"/"}>Fleet log</.link>
          <.link navigate={~p"/progress"} aria-current="page">Progress</.link>
        </nav>
      </header>

      <.progress_charts :if={@stats} stats={@stats} capped={@capped} />

      <section class="plate">
        <h2>PRs, issues, and achievements</h2>
        <p :if={@projections == []} class="empty-state">
          No PRs, issues, or achievements recorded.
        </p>
        <p :if={@total > 0} class="meta">
          Showing {window_start(@page, @total)}–{window_end(@page, @projections)} of {@total}
        </p>

        <.progress_table
          :if={@projections != []}
          id="progress-rows"
          projections={@projections}
          detail_path={&detail_path(@page, &1)}
        />

        <nav :if={@total_pages > 1} class="pager" aria-label="Progress pages">
          <.link :if={@page > 1} patch={~p"/progress?page=#{@page - 1}"} rel="prev">prev</.link>
          <span :if={@page == 1} class="pager-off">prev</span>
          <.link
            :for={n <- page_numbers(@page, @total_pages)}
            patch={~p"/progress?page=#{n}"}
            aria-current={@page == n && "page"}
          >
            {n}
          </.link>
          <.link :if={@page < @total_pages} patch={~p"/progress?page=#{@page + 1}"} rel="next">
            next
          </.link>
          <span :if={@page >= @total_pages} class="pager-off">next</span>
        </nav>
      </section>

      <.progress_details
        projection={@detail}
        close_path={close_path(@page)}
        event_path={fn offset -> detail_path(@page, @detail.item.id) <> "&event_offset=#{offset}" end}
      />
    </Layouts.app>
    """
  end

  defp detail_path(page, id), do: ~p"/progress?page=#{page}&item=#{id}"
  defp close_path(page), do: ~p"/progress?page=#{page}"

  # A deep link may name a row that is not on this page, so fall back to
  # fetching it directly rather than only searching the loaded page.
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

  defp parse_page(nil), do: 1

  defp parse_page(raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp ceil_div(total, limit), do: div(total + limit - 1, limit)

  defp window_start(page, total) do
    min((page - 1) * ProgressItem.page_size() + 1, total)
  end

  defp window_end(page, projections) do
    (page - 1) * ProgressItem.page_size() + length(projections)
  end

  defp page_numbers(page, total_pages) do
    Enum.to_list(max(1, page - 2)..min(total_pages, page + 2))
  end
end
