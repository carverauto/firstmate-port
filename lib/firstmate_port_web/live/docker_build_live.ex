defmodule FirstmatePortWeb.DockerBuildLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.DockerBuild

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case DockerBuild.get(id, FirstmatePort.Tenancy.opts(socket.assigns.current_user)) do
      {:ok, build} -> {:noreply, assign(socket, build: build, page_title: build.tag)}
      {:error, _} -> {:noreply, push_navigate(socket, to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div :if={@build}>
        <header class="page-head">
          <h1>Docker build</h1>
        </header>
        <dl class="facts">
          <dt>repository</dt>
          <dd>{@build.repository}</dd>
          <dt>tag</dt>
          <dd>{@build.tag}</dd>
          <dt>status</dt>
          <dd>{@build.status}</dd>
          <dt>digest</dt>
          <dd>{@build.digest}</dd>
          <dt>dockerfile</dt>
          <dd>{@build.dockerfile}</dd>
          <dt>context</dt>
          <dd>{@build.context}</dd>
          <dt>PR</dt>
          <dd><a :if={@build.pr_url != ""} href={@build.pr_url}>{@build.pr_url}</a></dd>
          <dt>issue</dt>
          <dd><a :if={@build.issue_url != ""} href={@build.issue_url}>{@build.issue_url}</a></dd>
          <dt>outcome</dt>
          <dd>{@build.outcome}</dd>
        </dl>
      </div>
      <p :if={!@build} class="empty-state" role="alert">This build is not on the board.</p>
    </Layouts.app>
    """
  end
end
