defmodule FirstmatePortWeb.BoardLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.GithubItem

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def handle_params(params, uri, socket) do
    kind = if String.contains?(uri, "/issues"), do: :issue, else: :pr
    {:ok, items} = load(kind, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:kind, kind)
     |> assign(:items, items)
     |> assign(:page_title, if(kind == :pr, do: "open PRs", else: "open issues"))
     |> assign(:filter, params["worker"] || "")}
  end

  defp load(:pr, actor), do: GithubItem.list_open_prs(FirstmatePort.Tenancy.opts(actor))
  defp load(:issue, actor), do: GithubItem.list_open_issues(FirstmatePort.Tenancy.opts(actor))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>{if @kind == :pr, do: "Open PRs", else: "Open issues"}</h1>
      </header>
      <p :if={@items == []} class="empty-state">
        Nothing open. GitHub poll fills this from html_url values copied off the API.
      </p>
      <ol class="rows">
        <li :for={item <- @items}>
          <span>
            <a href={item.html_url}>{item.title}</a>
            <span class="kind">{item.check_status}</span>
            <span :if={item.firewall_verdict not in [nil, :none, "none"]} class="kind">
              firewall {item.firewall_verdict}
            </span>
          </span>
          <span class="meta">
            {item.assignment_task_id} {item.assignment_worker} {item.assignment_status}
            <a :if={item.buildbuddy_url not in [nil, ""]} href={item.buildbuddy_url}>invocation</a>
          </span>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
