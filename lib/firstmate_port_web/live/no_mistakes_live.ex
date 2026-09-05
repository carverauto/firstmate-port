defmodule FirstmatePortWeb.NoMistakesLive do
  @moduledoc """
  LiveView recreation of `no-mistakes axi` home/run/status/respond/logs.
  The daemon stays on the Mac; this page is the LAN human TUI.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.NoMistakesRun

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    {:ok, runs} = NoMistakesRun.list(FirstmatePort.Tenancy.opts(actor))

    {:ok,
     socket
     |> assign(:page_title, "no-mistakes")
     |> assign(:runs, runs)
     |> assign(:selected, List.first(runs))
     |> assign(:pane, "home")
     |> assign(:respond_action, "approve")
     |> assign(:respond_findings, "")
     |> assign(:respond_instructions, "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    pane = params["pane"] || "home"
    selected = pick(socket.assigns.runs, params["run"]) || socket.assigns.selected
    {:noreply, socket |> assign(:pane, pane) |> assign(:selected, selected)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/no-mistakes?pane=#{socket.assigns.pane}&run=#{id}")}
  end

  def handle_event("respond", params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, put_flash(socket, :error, "no run selected")}

      run ->
        attrs = %{
          respond_action: params["action"] || "approve",
          respond_findings: params["findings"] || "",
          respond_instructions: params["instructions"] || ""
        }

        case NoMistakesRun.human_respond(
               run,
               attrs,
               FirstmatePort.Tenancy.opts(socket.assigns.current_user)
             ) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:selected, updated)
             |> put_flash(:info, "respond recorded for firstmate")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, inspect(error))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>no-mistakes</h1>
        <p class="meta">axi home / run / status / respond / logs. Daemon stays on the Mac.</p>
      </header>

      <nav class="nav" aria-label="no-mistakes panes">
        <.link patch={~p"/no-mistakes?pane=home"} aria-current={@pane == "home" && "page"}>
          home
        </.link>
        <.link patch={~p"/no-mistakes?pane=run"} aria-current={@pane == "run" && "page"}>run</.link>
        <.link patch={~p"/no-mistakes?pane=status"} aria-current={@pane == "status" && "page"}>
          status
        </.link>
        <.link patch={~p"/no-mistakes?pane=respond"} aria-current={@pane == "respond" && "page"}>
          respond
        </.link>
        <.link patch={~p"/no-mistakes?pane=logs"} aria-current={@pane == "logs" && "page"}>
          logs
        </.link>
      </nav>

      <div class="axi-split">
        <aside class="plate">
          <h2>runs</h2>
          <p :if={@runs == []} class="empty-state">
            No runs posted. Firstmate keeps ~/.no-mistakes on this Mac.
          </p>
          <ol class="rows">
            <li :for={n <- @runs}>
              <button type="button" phx-click="select" phx-value-id={n.id} class="btn btn-quiet">
                <span class="kind">{n.outcome || n.step || "run"}</span>
                {n.branch}
              </button>
              <span class="meta">{n.run_id}</span>
            </li>
          </ol>
        </aside>

        <section :if={@pane == "home"} class="plate">
          <h2>home</h2>
          <p class="empty-copy">
            Current branch runs, next gate, and PR URLs. Details stay here; Discord only gets a generic ping.
          </p>
          <div :if={@selected} class="facts">
            <span>run</span><span>{@selected.run_id}</span>
            <span>branch</span><span>{@selected.branch}</span>
            <span>step</span><span>{@selected.step}</span>
            <span>outcome</span><span>{@selected.outcome}</span>
            <span>firewall</span><span>{@selected.firewall_verdict}</span>
            <span>pr</span>
            <a :if={@selected.pr_url != ""} href={@selected.pr_url}>{@selected.pr_url}</a>
          </div>
        </section>

        <section :if={@pane == "run"} class="plate">
          <h2>run</h2>
          <p class="empty-copy">
            Intent captured with the run. Starting a pipeline still happens via `no-mistakes axi run` on the Mac.
          </p>
          <pre :if={@selected}>{@selected.intent}</pre>
        </section>

        <section :if={@pane == "status"} class="plate">
          <h2>status</h2>
          <div :if={@selected} class="facts">
            <span>step</span><span>{@selected.step}</span>
            <span>outcome</span><span>{@selected.outcome}</span>
            <span>respond</span><span>{@selected.respond_action} {@selected.respond_at}</span>
          </div>
          <h3>findings (LAN only)</h3>
          <pre :if={@selected}>{@selected.findings}</pre>
        </section>

        <section :if={@pane == "respond"} class="plate">
          <h2>respond</h2>
          <p class="empty-copy">
            Same decisions as `no-mistakes axi respond`. Firstmate reads this; never --yes.
          </p>
          <form phx-submit="respond" class="axi-form">
            <label>
              action
              <select name="action">
                <option value="approve">approve</option>
                <option value="fix">fix</option>
                <option value="skip">skip</option>
              </select>
            </label>
            <label>
              findings <input type="text" name="findings" value={@respond_findings} />
            </label>
            <label>
              instructions <textarea name="instructions">{@respond_instructions}</textarea>
            </label>
            <button type="submit" class="tab on">record respond</button>
          </form>
        </section>

        <section :if={@pane == "logs"} class="plate">
          <h2>logs</h2>
          <pre :if={@selected}>{@selected.logs}</pre>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp pick(runs, nil), do: List.first(runs)
  defp pick(runs, id), do: Enum.find(runs, List.first(runs), &(&1.id == id))
end
