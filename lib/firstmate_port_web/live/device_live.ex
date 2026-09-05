defmodule FirstmatePortWeb.DeviceLive do
  @moduledoc "Browser approval for firstmatectl device-code login."
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Auth.DeviceCode

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(params, _session, socket) do
    user_code = params["user_code"] || ""

    {:ok,
     socket
     |> assign(:page_title, "Authorize CLI")
     |> assign(:user_code, user_code)
     |> assign(:status, :pending)}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    user = socket.assigns.current_user

    case DeviceCode.get_by_user_code(socket.assigns.user_code, authorize?: false) do
      {:ok, code} ->
        {:ok, _} =
          DeviceCode.approve(code, %{user_id: user.id, tenant_slug: user.tenant_slug},
            authorize?: false
          )

        {:noreply, assign(socket, :status, :approved)}

      _ ->
        {:noreply, assign(socket, :status, :missing)}
    end
  end

  def handle_event("deny", _params, socket) do
    case DeviceCode.get_by_user_code(socket.assigns.user_code, authorize?: false) do
      {:ok, code} ->
        {:ok, _} = DeviceCode.deny(code, %{}, authorize?: false)
        {:noreply, assign(socket, :status, :denied)}

      _ ->
        {:noreply, assign(socket, :status, :missing)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Authorize firstmatectl</h1>
      </header>
      <p :if={@status == :pending} class="lede">
        Confirm this code matches the CLI, then approve. The CLI talks only to this API.
      </p>
      <p class="kind">{@user_code}</p>
      <div :if={@status == :pending}>
        <button type="button" class="btn btn-primary" phx-click="approve">Approve</button>
        <button type="button" class="btn btn-quiet" phx-click="deny">Deny</button>
      </div>
      <p :if={@status == :approved} class="empty-copy">Approved. Return to the CLI.</p>
      <p :if={@status == :denied} class="empty-copy" role="alert">Denied.</p>
      <p :if={@status == :missing} class="empty-copy" role="alert">Unknown or expired code.</p>
    </Layouts.app>
    """
  end
end
