defmodule FirstmatePortWeb.BuildBuddyLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.BuildBuddyInvocation

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case BuildBuddyInvocation.get(id, FirstmatePort.Tenancy.opts(socket.assigns.current_user)) do
      {:ok, invocation} ->
        {:noreply, assign(socket, invocation: invocation, page_title: invocation.invocation_id)}

      {:error, _} ->
        {:noreply, push_navigate(socket, to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div :if={@invocation}>
        <header class="page-head">
          <h1>BuildBuddy invocation</h1>
        </header>
        <dl class="facts">
          <dt>invocation</dt>
          <dd>{@invocation.invocation_id}</dd>
          <dt>status</dt>
          <dd>{@invocation.status}</dd>
          <dt>commit</dt>
          <dd>{@invocation.commit_sha}</dd>
          <dt>branch</dt>
          <dd>{@invocation.branch}</dd>
          <dt>repo</dt>
          <dd>{@invocation.repo_url}</dd>
          <dt>buildbuddy</dt>
          <dd>
            <a :if={@invocation.buildbuddy_url != ""} href={@invocation.buildbuddy_url}>
              {@invocation.buildbuddy_url}
            </a>
          </dd>
          <dt>PR</dt>
          <dd>
            <a :if={@invocation.pr_url != ""} href={@invocation.pr_url}>{@invocation.pr_url}</a>
          </dd>
          <dt>outcome</dt>
          <dd>{@invocation.outcome}</dd>
        </dl>
      </div>
      <p :if={!@invocation} class="empty-state" role="alert">This invocation is not on the board.</p>
    </Layouts.app>
    """
  end
end
