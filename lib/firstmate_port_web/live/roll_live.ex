defmodule FirstmatePortWeb.RollLive do
  @moduledoc false
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.Roll

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Roll.get(id, FirstmatePort.Tenancy.opts(socket.assigns.current_user)) do
      {:ok, roll} -> {:noreply, assign(socket, roll: roll, page_title: roll.image_tag)}
      {:error, _} -> {:noreply, push_navigate(socket, to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div :if={@roll}>
        <header class="page-head">
          <h1>{@roll.cluster} roll</h1>
        </header>
        <dl class="facts">
          <dt>status</dt>
          <dd>{@roll.status}</dd>
          <dt>namespace</dt>
          <dd>{@roll.namespace}</dd>
          <dt>image tag</dt>
          <dd>{@roll.image_tag}</dd>
          <dt>helm revision</dt>
          <dd>{@roll.helm_revision}</dd>
          <dt>rebuilt</dt>
          <dd>{Enum.join(@roll.rebuilt, ", ")}</dd>
          <dt>copied</dt>
          <dd>{Enum.join(@roll.copied, ", ")}</dd>
          <dt>PR</dt>
          <dd><a :if={@roll.pr_url != ""} href={@roll.pr_url}>{@roll.pr_url}</a></dd>
          <dt>issue</dt>
          <dd><a :if={@roll.issue_url != ""} href={@roll.issue_url}>{@roll.issue_url}</a></dd>
          <dt>outcome</dt>
          <dd>{@roll.outcome}</dd>
        </dl>
      </div>
      <p :if={!@roll} class="empty-state" role="alert">This roll is not on the board.</p>
    </Layouts.app>
    """
  end
end
