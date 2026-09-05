defmodule FirstmatePortWeb.CredentialsLive do
  @moduledoc """
  Where a tenant fills its own credential slots.

  Secrets go one way. A stored value is never assigned back into the socket or
  rendered, so the page shows the slot, a hint (see `Slots.hint/1`), and the byte
  size; a secret that went in wrong is fixed by rotating it, not by reading it
  back.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Credentials
  # `Errors.describe/1`, never `Exception.message/1` or `inspect/1`: Ash's own
  # error messages end in the rejected value, which here is the secret.
  alias FirstmatePort.Credentials.{Credential, Errors, Slots}
  alias FirstmatePort.Tenancy

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @custom "custom"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "credentials")
     |> assign(:tenant, Tenancy.slug(socket.assigns.current_user))
     |> assign(:slot, default_slot())
     |> assign(:custom, @custom)
     # Bumped after every write so the browser replaces the form that was typed
     # into. That is how the secret leaves the page without entering an assign.
     |> assign(:form_version, 0)
     |> assign(:error, nil)
     |> load_credentials()}
  end

  @impl true
  def handle_event("select_slot", %{"slot" => slot}, socket) do
    {:noreply, assign(socket, :slot, slot)}
  end

  def handle_event("save", params, socket) do
    {provider, key} = slot_fields(socket.assigns.slot, params)

    attrs = %{
      provider: String.trim(provider || ""),
      key: String.trim(key || ""),
      value: params["value"] || "",
      description: String.trim(params["description"] || "")
    }

    write(socket, "#{attrs.provider}/#{attrs.key} saved", fn opts ->
      Credentials.put(attrs, opts)
    end)
  end

  def handle_event("rotate", %{"provider" => provider, "key" => key} = params, socket) do
    write(socket, "#{provider}/#{key} rotated", fn opts ->
      with {:ok, credential} <- find(provider, key, opts) do
        Credential.rotate(credential, %{value: params["value"] || ""}, opts)
      end
    end)
  end

  def handle_event("delete", %{"provider" => provider, "key" => key}, socket) do
    write(socket, "#{provider}/#{key} removed", fn opts ->
      with {:ok, credential} <- find(provider, key, opts) do
        Credential.destroy(credential, opts)
      end
    end)
  end

  defp find(provider, key, opts) do
    case Credential.get_slot(provider, key, opts) do
      {:ok, nil} -> {:error, "#{provider}/#{key} is not stored for this tenant"}
      {:ok, credential} -> {:ok, credential}
      {:error, error} -> {:error, error}
    end
  end

  defp write(socket, success, fun) do
    case fun.(opts(socket)) do
      {:error, error} ->
        {:noreply, assign(socket, :error, Errors.describe(error))}

      _ok ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> update(:form_version, &(&1 + 1))
         |> put_flash(:info, success)
         |> load_credentials()}
    end
  end

  defp opts(socket), do: Tenancy.opts(socket.assigns.current_user)

  defp load_credentials(socket) do
    case Credential.list(opts(socket)) do
      {:ok, rows} ->
        assign(socket, :credentials, Enum.sort_by(rows, &{&1.provider, &1.key}))

      {:error, error} ->
        socket |> assign(:credentials, []) |> assign(:error, Errors.describe(error))
    end
  end

  defp slot_fields(@custom, params), do: {params["provider"], params["key"]}

  defp slot_fields(slot, _params) do
    case String.split(slot, "/", parts: 2) do
      [provider, key] -> {provider, key}
      _ -> {"", ""}
    end
  end

  defp default_slot do
    [%{provider: provider, key: key} | _] = Slots.catalog()
    "#{provider}/#{key}"
  end

  defp slot_options do
    Enum.map(Slots.catalog(), fn slot -> {slot.label, "#{slot.provider}/#{slot.key}"} end) ++
      [{"Something else", @custom}]
  end

  defp about(slot) do
    with [provider, key] <- String.split(slot, "/", parts: 2),
         {:ok, %{about: about}} <- Slots.fetch(provider, key) do
      about
    else
      _ -> "A slot of your own: any provider and key this portal reads by name."
    end
  end

  defp shown(%{hint: ""} = credential), do: "#{credential.value_bytes} bytes"
  defp shown(credential), do: "ends #{credential.hint} - #{credential.value_bytes} bytes"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Credentials</h1>
        <p class="meta">
          Tenant <span class="kind">{@tenant}</span>. Encrypted before it reaches Postgres, and
          never shown again.
        </p>
      </header>

      <p :if={@error} class="empty-copy" role="alert">{@error}</p>

      <section class="plate">
        <h2>Add or replace</h2>
        <form phx-change="select_slot" class="axi-form">
          <label>
            Slot
            <select name="slot">
              <option :for={{label, value} <- slot_options()} value={value} selected={value == @slot}>
                {label}
              </option>
            </select>
          </label>
        </form>
        <p class="hint">{about(@slot)}</p>

        <form id={"credential-form-#{@form_version}"} phx-submit="save" class="axi-form">
          <label :if={@slot == @custom}>
            Provider <input type="text" name="provider" autocomplete="off" placeholder="stripe" />
          </label>
          <label :if={@slot == @custom}>
            Key <input type="text" name="key" autocomplete="off" placeholder="api_key" />
          </label>
          <label>
            Secret
            <input type="password" name="value" autocomplete="off" spellcheck="false" required />
          </label>
          <label>
            Note (optional)
            <input type="text" name="description" autocomplete="off" maxlength="500" />
          </label>
          <button type="submit" class="btn btn-primary">Save</button>
        </form>
      </section>

      <section class="plate">
        <h2>Stored</h2>
        <p :if={@credentials == []} class="empty-state">
          Nothing stored yet. Save this tenant's <span class="kind">discord/public_key</span>
          here before configuring Discord interactions. Environment keys are not accepted.
        </p>
        <ol class="rows">
          <li :for={credential <- @credentials}>
            <span>
              <span class="kind">{credential.provider}/{credential.key}</span>
              <span class="meta">{shown(credential)}</span>
              <span :if={credential.description != ""} class="meta">{credential.description}</span>
              <form
                id={"rotate-#{credential.provider}-#{credential.key}-#{@form_version}"}
                phx-submit="rotate"
                class="axi-form"
              >
                <input type="hidden" name="provider" value={credential.provider} />
                <input type="hidden" name="key" value={credential.key} />
                <label>
                  Replace
                  <input
                    type="password"
                    name="value"
                    autocomplete="off"
                    spellcheck="false"
                    required
                  />
                </label>
                <button type="submit" class="btn btn-quiet">Rotate</button>
              </form>
            </span>
            <span>
              <time class="meta">{credential.rotated_at || credential.updated_at}</time>
              <button
                type="button"
                class="btn btn-quiet"
                phx-click="delete"
                phx-value-provider={credential.provider}
                phx-value-key={credential.key}
                data-confirm={"Delete #{credential.provider}/#{credential.key}?"}
              >
                Delete
              </button>
            </span>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
