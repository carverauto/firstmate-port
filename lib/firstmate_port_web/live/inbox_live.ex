defmodule FirstmatePortWeb.InboxLive do
  @moduledoc """
  The traffic between firstmate, the second mate, and the crew, as it happens.

  This is the window onto `FirstmatePort.Inbox`: the same rows `fm-steer inbox`
  writes and reads, so an order the captain sends here is one the crew takes
  with `fm-steer inbox next`, and a "this is done" the second mate files from a
  script shows up on this page without a reload. There is one inbox per tenant
  and `task` routes within it; nothing here is a second queue.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Inbox
  alias FirstmatePort.Tenancy

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @keep 200

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    tenant = Tenancy.slug(actor)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Inbox.topic(tenant))
    end

    {:ok,
     socket
     |> assign(:page_title, "inbox")
     |> assign(:tenant, tenant)
     |> assign(:default_task, Inbox.default_task())
     # Bumped after a send so the browser gets a blank compose box back.
     |> assign(:form_version, 0)
     |> assign(:error, nil)
     |> load_messages()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :filter, params["task"] || "")}
  end

  @impl true
  def handle_event("send", params, socket) do
    attrs = %{
      "task" => params["task"] || "",
      "body" => params["body"] || "",
      "delivery" => params["delivery"] || ""
    }

    case Inbox.put(socket.assigns.current_user, attrs) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:messages, merge(socket.assigns.messages, message))
         |> update(:form_version, &(&1 + 1))
         |> put_flash(:info, "Order filed.")}

      {:error, :invalid} ->
        {:noreply, assign(socket, :error, "An order needs a body.")}

      {:error, _} ->
        {:noreply, assign(socket, :error, "Could not file that order.")}
    end
  end

  def handle_event("ack", %{"ack" => ack}, socket) do
    case Inbox.ack(socket.assigns.current_user, ack) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:messages, merge(socket.assigns.messages, message))}

      {:error, _} ->
        {:noreply, assign(socket, :error, "That message is no longer here.")}
    end
  end

  @impl true
  def handle_info({:inbox_message, message}, socket) do
    {:noreply, assign(socket, :messages, merge(socket.assigns.messages, message))}
  end

  # A message that is already on the page was claimed or acked, so it is
  # replaced in place; anything else is new and goes on top. Sorting by seq
  # rather than arrival keeps the order stable when both happen at once, and
  # makes this idempotent: the broadcast that follows the captain's own action
  # lands on a row that is already correct.
  defp merge(messages, message) do
    messages
    |> Enum.reject(&(&1["ack"] == message["ack"]))
    |> List.insert_at(0, message)
    |> Enum.sort_by(& &1["seq"], :desc)
    |> Enum.take(@keep)
  end

  defp load_messages(socket) do
    case Inbox.recent(socket.assigns.current_user) do
      {:ok, messages} ->
        assign(socket, :messages, messages)

      {:error, _} ->
        socket |> assign(:messages, []) |> assign(:error, "Could not read the inbox.")
    end
  end

  defp shown(messages, ""), do: messages
  defp shown(messages, task), do: Enum.filter(messages, &(&1["task"] == task))

  defp tasks(messages), do: messages |> Enum.map(& &1["task"]) |> Enum.uniq() |> Enum.sort()

  defp waiting(messages), do: Enum.count(messages, &(&1["status"] != "acked"))

  defp who(""), do: "unattributed"
  defp who(email), do: email

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Inbox</h1>
        <nav :if={tasks(@messages) != []} class="nav" aria-label="Task filter">
          <.link patch={~p"/inbox"} aria-current={@filter == "" && "page"}>All</.link>
          <.link
            :for={task <- tasks(@messages)}
            patch={~p"/inbox?task=#{task}"}
            aria-current={@filter == task && "page"}
          >
            {task}
          </.link>
        </nav>
      </header>

      <p class="meta">
        Tenant <span class="kind">{@tenant}</span>. One queue both ways:
        <span class="kind">fm-steer inbox put</span>
        files here, <span class="kind">fm-steer inbox next</span>
        takes the oldest one. {waiting(@messages)} waiting.
      </p>

      <p :if={@error} class="empty-copy" role="alert">{@error}</p>

      <section class="plate">
        <h2>Send an order</h2>
        <form id={"order-form-#{@form_version}"} phx-submit="send" class="axi-form">
          <label>
            Task
            <input
              type="text"
              name="task"
              autocomplete="off"
              placeholder={@default_task}
              value={@filter}
            />
          </label>
          <label>
            Order <textarea name="body" rows="3" required placeholder="What the crew should do next"></textarea>
          </label>
          <label>
            Delivery note (optional)
            <input type="text" name="delivery" autocomplete="off" maxlength="500" />
          </label>
          <button type="submit" class="btn btn-primary">Send</button>
        </form>
        <p class="hint">
          A blank task files under <span class="kind">{@default_task}</span>, firstmate's own
          mailbox. Any other task addresses that crew lane.
        </p>
      </section>

      <section class="plate">
        <h2>Traffic</h2>
        <p :if={shown(@messages, @filter) == []} class="empty-state">
          Nothing has passed through yet. The mates talk here instead of handing each other files.
        </p>
        <ol class="rows">
          <li :for={message <- shown(@messages, @filter)} id={"message-" <> message["ack"]}>
            <span>
              <span class="kind">{message["task"]} #{message["seq"]}</span>
              <span class="kind">{message["status"]}</span>
              <pre>{message["body"]}</pre>
              <span class="meta">
                from {who(message["sender"])}
                <span :if={message["claimed_by"] not in [nil, ""]}>
                  - taken by {message["claimed_by"]}
                </span>
                <span :if={message["delivery"] not in [nil, ""]}>
                  - deliver via {message["delivery"]}
                </span>
              </span>
            </span>
            <span>
              <time class="meta">{message["at"]}</time>
              <button
                :if={message["status"] != "acked"}
                type="button"
                class="btn btn-quiet"
                phx-click="ack"
                phx-value-ack={message["ack"]}
              >
                Ack
              </button>
            </span>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
