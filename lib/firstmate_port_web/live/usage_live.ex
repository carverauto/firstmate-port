defmodule FirstmatePortWeb.UsageLive do
  @moduledoc """
  Per-account token usage and remaining allowance. Same numbers as
  `GET /api/usage` and `fm-steer usage`: allowance, used, remaining,
  status, provider window, spend priority, and runway from snapshots.
  """
  use FirstmatePortWeb, :live_view

  alias FirstmatePort.Portal.{UsageAccount, UsageSnapshot}
  alias FirstmatePort.{Tenancy, Usage}
  alias FirstmatePort.Usage.Sync

  on_mount {FirstmatePortWeb.LiveUser, :require_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "usage")
     |> assign(:form, to_form(%{}))
     |> load_accounts()}
  end

  @impl true
  def handle_event("save", %{"account" => params}, socket) do
    actor = socket.assigns.current_user

    case UsageAccount.record(record_attrs(params), Tenancy.opts(actor)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{}))
         |> load_accounts()
         |> put_flash(:info, "account saved")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "could not save: #{short(error)}")}
    end
  end

  def handle_event("sync", _params, socket) do
    case Sync.sync_all(socket.assigns.current_user) do
      {:ok, results} ->
        synced = Enum.count(results, & &1.synced?)

        {:noreply,
         socket
         |> load_accounts()
         |> put_flash(:info, "sync refreshed #{synced} of #{length(results)} accounts")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "sync failed: #{short(error)}")}
    end
  end

  defp load_accounts(socket) do
    actor = socket.assigns.current_user
    opts = Tenancy.opts(actor)
    {:ok, accounts} = UsageAccount.list(opts)

    rows =
      accounts
      |> Usage.sort_for_spend()
      |> Enum.map(fn account ->
        {:ok, snaps} = UsageSnapshot.for_account(account.id, opts)
        Usage.summarize(account, snaps)
      end)

    assign(socket, :accounts, rows)
  end

  defp record_attrs(params) do
    %{provider: params["provider"], label: empty_to_nil(params["label"]) || params["provider"]}
    |> put_given(:unit, empty_to_nil(params["unit"]))
    |> put_given(:allowance, parse_float(params["allowance"]))
    |> put_given(:used, parse_float(params["used"]))
    |> put_given(:window, empty_to_nil(params["window"]))
    |> put_given(:spend_priority, parse_int(params["spend_priority"]))
    |> put_given(:notes, empty_to_nil(params["notes"]))
  end

  defp put_given(attrs, _key, nil), do: attrs
  defp put_given(attrs, key, value), do: Map.put(attrs, key, value)

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(s), do: s

  defp parse_float(nil), do: nil
  defp parse_float(""), do: nil

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp short(error) do
    error |> inspect() |> String.slice(0, 160)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="page-head">
        <h1>Usage</h1>
        <p class="meta">
          Token and billing counters per provider account. Same ledger as <code>fm-steer usage</code>
          and <code>GET /api/usage</code>.
        </p>
        <button phx-click="sync" class="btn btn-quiet">Sync providers</button>
      </header>

      <section class="plate">
        <h2>Accounts</h2>
        <p :if={@accounts == []} class="empty-state">
          No accounts yet. Add one below, or POST /api/usage.
        </p>
        <ol class="rows">
          <li :for={a <- @accounts}>
            <span>
              <span class="kind">{a.status}</span>
              <strong>{a.provider} / {a.label}</strong>
              <span class="meta">
                {fmt(a.used)} / {fmt(a.allowance)} {a.unit} · {a.window} · priority {a.spend_priority} · {a.source}
              </span>
              <span :if={a.runway_days} class="meta">runway {a.runway_days}d</span>
              <span :if={is_nil(a.runway_days)} class="meta">runway unknown</span>
              <span class="meter" aria-hidden="true"><span style={"width: #{bar(a)}%"} /></span>
            </span>
            <span class="meta">remaining {fmt(a.remaining)}</span>
          </li>
        </ol>
      </section>

      <section class="plate">
        <h2>Add account</h2>
        <.form for={@form} phx-submit="save" id="usage-form">
          <div class="grid-form">
            <label>
              Provider
              <input name="account[provider]" required maxlength="64" placeholder="openrouter" />
            </label>
            <label>Label <input name="account[label]" maxlength="128" placeholder="captain" /></label>
            <label>
              Unit
              <select name="account[unit]">
                <option value="">unchanged</option>
                <option value="usd">usd</option>
                <option value="tokens">tokens</option>
                <option value="credits">credits</option>
              </select>
            </label>
            <label>
              Allowance <input name="account[allowance]" inputmode="decimal" placeholder="100" />
            </label>
            <label>Used <input name="account[used]" inputmode="decimal" placeholder="0" /></label>
            <label>
              Window
              <select name="account[window]">
                <option value="">unchanged</option>
                <option value="monthly">monthly</option>
                <option value="weekly">weekly</option>
                <option value="daily">daily</option>
                <option value="one_time">one_time</option>
              </select>
            </label>
            <label>
              Spend priority
              <input name="account[spend_priority]" inputmode="numeric" placeholder="100" />
            </label>
          </div>
          <button type="submit" class="btn btn-primary">Save account</button>
        </.form>
        <p class="meta">
          Lower spend priority burns first. Provider keys stay server-side env vars;
          only OpenRouter syncs live today — the rest are manual or agent-posted.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp fmt(nil), do: "-"
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp fmt(other), do: to_string(other)

  defp bar(%{pct_used: nil}), do: 0
  defp bar(%{pct_used: p}), do: p |> Kernel.*(100) |> min(100) |> round()
end
