defmodule FirstmatePortWeb.CredentialsLive do
  @moduledoc """
  Where a tenant fills its own credential slots.

  Secrets go one way. A stored value is never assigned back into the socket or
  rendered, so the page shows the slot, a hint (see `Slots.hint/1`), and the byte
  size; a secret that went in wrong is fixed by rotating it, not by reading it
  back.
  """

  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Accounts.Tenant
  alias FirstmatePort.Credentials
  # `Errors.describe/1`, never `Exception.message/1` or `inspect/1`: Ash's own
  # error messages end in the rejected value, which here is the secret.
  alias FirstmatePort.Credentials.{Credential, Discord, Errors, Slots}
  alias FirstmatePort.Discord.Attempts
  alias FirstmatePort.Fleet.Embeddings
  alias FirstmatePort.Tenancy
  alias FirstmatePortWeb.DiscordHosts

  on_mount({FirstmatePortWeb.LiveUser, :require_user})

  @custom "custom"

  @impl true
  def mount(_params, _session, socket) do
    tenant = Tenancy.slug(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "credentials")
     |> assign(:tenant, tenant)
     |> assign(:interactions_url, DiscordHosts.interactions_url())
     |> assign(:slot, default_slot())
     |> assign(:custom, @custom)
     # Bumped after every write so the browser replaces the form that was typed
     # into. That is how the secret leaves the page without entering an assign.
     |> assign(:form_version, 0)
     |> assign(:error, nil)
     |> load_application_id()
     |> load_credentials()
     |> load_embeddings()
     |> watch_endpoint()}
  end

  # A refusal arrives while the operator is looking at the page - that is the
  # whole point of it - so the panel follows the tenant's own topic rather than
  # making them reload to find out what Discord just got.
  defp watch_endpoint(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FirstmatePort.PubSub, Attempts.topic(socket.assigns.tenant))
    end

    load_endpoint(socket)
  end

  defp load_endpoint(socket) do
    tenant = socket.assigns.tenant

    socket
    |> assign(:key_state, Discord.public_key(tenant))
    |> assign(:attempts, Attempts.list(tenant))
  end

  @impl true
  def handle_info({:discord_attempt, _attempt}, socket) do
    {:noreply, load_endpoint(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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

  def handle_event("claim_application", %{"application_id" => application_id}, socket) do
    claim = String.trim(application_id)

    write(socket, claim_message(claim), fn opts ->
      with {:ok, tenant} <- Tenant.get_by_slug(socket.assigns.tenant, opts) do
        # Blank releases the claim, which is how a tenant hands its application
        # to another one without an operator touching the database.
        Tenant.claim_discord_application(
          tenant,
          %{discord_application_id: if(claim == "", do: nil, else: claim)},
          opts
        )
      end
    end)
  end

  def handle_event("rotate", %{"provider" => provider, "key" => key} = params, socket) do
    write(socket, "#{provider}/#{key} rotated", fn opts ->
      with {:ok, credential} <- find(provider, key, opts) do
        Credential.rotate(credential, %{value: params["value"] || ""}, opts)
      end
    end)
  end

  def handle_event("set_embedding_model", %{"model" => model}, socket) do
    actor = socket.assigns.current_user

    with {:ok, tenant} <- Tenant.get_by_slug(Tenancy.slug(actor), actor: actor),
         {:ok, _updated} <-
           Tenant.set_embedding_model(tenant, %{embedding_model: model}, actor: actor) do
      {:noreply, socket |> assign(:error, nil) |> load_embeddings()}
    else
      {:error, error} -> {:noreply, assign(socket, :error, Errors.describe(error))}
    end
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
         |> load_application_id()
         |> load_credentials()
         |> load_embeddings()
         |> load_endpoint()}
    end
  end

  defp opts(socket), do: Tenancy.opts(socket.assigns.current_user)

  defp load_embeddings(socket) do
    actor = socket.assigns.current_user

    chosen =
      case Tenant.get_by_slug(Tenancy.slug(actor), actor: actor) do
        {:ok, %Tenant{embedding_model: model}} -> model
        _ -> ""
      end

    socket
    |> assign(:embedding_model, chosen)
    |> assign(:embedding_state, Embeddings.state(actor))
  end

  defp embedding_summary(:off) do
    "Off. Nothing from this fleet log is sent anywhere."
  end

  defp embedding_summary(:missing_api_key) do
    "A model is chosen. Save an embeddings/api_key credential above to switch semantic search on."
  end

  defp embedding_summary({:ready, model}), do: "On, using #{model}."

  defp key_summary({:ok, _key}), do: "Stored. Interactions for this tenant verify against it."

  defp key_summary({:error, :no_key}) do
    "Not stored. Paste the application's Public Key below as discord/public_key - " <>
      "until you do, every signed interaction for this tenant is refused."
  end

  defp key_summary({:error, :unreadable_key}) do
    "Stored, but the vault would not decrypt it. That is a CLOAK_KEY problem, " <>
      "not a Discord one - see docs/credentials.md, 'Rotating the vault key'."
  end

  defp key_summary({:error, :unusable_key}) do
    "Stored, but it is not 64 hex characters. Rotate it below with the value from " <>
      "the developer portal's General Information page."
  end

  defp claim_summary(application_id, tenant) when application_id in [nil, ""] do
    if tenant == Tenancy.default_slug() do
      "Unclaimed - this default tenant answers for any application no one claimed."
    else
      "Unclaimed - claim your Discord application ID below to route interactions to this tenant."
    end
  end

  defp claim_summary(application_id, _tenant) do
    "Claimed: #{application_id}. Only interactions naming it are verified with this tenant's key."
  end

  # Discord's interaction types, named so the row says what arrived rather than
  # a bare number.
  defp interaction_name(1), do: "PING"
  defp interaction_name(2), do: "COMMAND"
  defp interaction_name(3), do: "COMPONENT"
  defp interaction_name(4), do: "AUTOCOMPLETE"
  defp interaction_name(5), do: "MODAL"
  defp interaction_name(nil), do: "unknown"
  defp interaction_name(type), do: "type #{type}"

  defp path_note(nil), do: ""
  defp path_note(path), do: ": #{path}"

  defp skew_note(nil), do: ""

  defp skew_note(seconds) do
    " (this node's clock is #{abs(seconds)}s #{if seconds > 0, do: "ahead of", else: "behind"} the signed timestamp)"
  end

  defp claim_message(""), do: "Discord application released"
  defp claim_message(_claim), do: "Discord application claimed"

  defp load_application_id(socket) do
    case Tenant.get_by_slug(socket.assigns.tenant, opts(socket)) do
      {:ok, %Tenant{discord_application_id: application_id}} ->
        assign(socket, :application_id, application_id)

      _ ->
        assign(socket, :application_id, nil)
    end
  end

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
        <h2>Discord interactions endpoint</h2>
        <p class="hint">
          Discord verifies this URL by sending it a signed PING, and reports any failure
          only as "the specified interactions endpoint url could not be verified". The
          endpoint answers every refusal with the same bare 401, so the reason is here
          instead.
        </p>

        <dl class="facts">
          <dt>endpoint URL</dt>
          <dd :if={@interactions_url}>
            <span class="kind">{@interactions_url}</span>
            - paste this into <strong>Interactions Endpoint URL</strong>, with no trailing slash.
          </dd>
          <dd :if={is_nil(@interactions_url)}>
            Not published. Set <span class="kind">DISCORD_INTERACTIONS_HOST</span>
            to serve interactions on their own hostname; without it the portal's own
            origin answers <span class="kind">/interactions</span>.
          </dd>
          <dt>public key</dt>
          <dd>{key_summary(@key_state)}</dd>
          <dt>application</dt>
          <dd>{claim_summary(@application_id, @tenant)}</dd>
        </dl>

        <h3>Recent inbound interactions</h3>
        <p :if={@attempts == []} class="empty-copy">
          Nothing has reached <span class="kind">/interactions</span>
          for this tenant in the last hour. Unclaimed applications route to the default tenant.
          {if @tenant != Tenancy.default_slug(),
            do: "Claim your Discord application ID below and confirm Discord is sending that application's ID."}
          Confirm the application routing before checking DNS and the HTTP route. Requests
          rejected before an application can be identified may appear only for the default tenant.

        </p>
        <table :if={@attempts != []} class="data-table">
          <thead>
            <tr>
              <th>when</th>
              <th>type</th>
              <th>outcome</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={attempt <- @attempts}>
              <td><time>{Calendar.strftime(attempt.at, "%Y-%m-%d %H:%M:%SZ")}</time></td>
              <td><span class="kind">{interaction_name(attempt.type)}</span></td>
              <td>
                {attempt.description}{skew_note(attempt.skew_seconds)}{path_note(attempt.path)}
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="plate">
        <h2>Discord application</h2>
        <p class="hint">
          The application id from the Discord developer portal, so interactions for that
          application are verified with this tenant's <span class="kind">discord/public_key</span>
          and published for this tenant. Not a secret - Discord sends it in every interaction.
          Leave it blank on a deployment that answers for a single application.
        </p>
        <form
          id={"discord-application-#{@form_version}"}
          phx-submit="claim_application"
          class="axi-form"
        >
          <label>
            Application id
            <input
              type="text"
              name="application_id"
              autocomplete="off"
              spellcheck="false"
              inputmode="numeric"
              maxlength="32"
              placeholder="1234567890123456789"
              value={@application_id}
            />
          </label>
          <button type="submit" class="btn btn-quiet">Save</button>
        </form>
      </section>

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
        <h2>Fleet-log embeddings</h2>
        <p class="meta">{embedding_summary(@embedding_state)}</p>
        <form phx-submit="set_embedding_model" class="axi-form">
          <label>
            Model
            <input
              type="text"
              name="model"
              value={@embedding_model}
              list="embedding-models"
              placeholder="openai:text-embedding-3-small"
              autocomplete="off"
              spellcheck="false"
            />
          </label>
          <datalist id="embedding-models">
            <option :for={model <- Embeddings.catalog()} value={model.spec}>{model.label}</option>
          </datalist>
          <button type="submit" class="btn btn-quiet">Save model</button>
        </form>
        <p class="hint">
          A <code>provider:model</code> spec; the box suggests the ones this portal knows by name,
          and any other model the provider library supports can be typed in. Empty disables
          embeddings. Semantic search is optional: choosing a model and saving that
          provider's key sends the indexed text of this fleet log - titles, progress notes, roll
          outcomes, no-mistakes findings - to that provider. Leave it off and search stays entirely
          in Postgres.
        </p>
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
