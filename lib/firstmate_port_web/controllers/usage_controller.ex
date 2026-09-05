defmodule FirstmatePortWeb.UsageController do
  @moduledoc """
  Portal-owned token usage / billing API. Every row is tenant-scoped;
  the tenant comes from the caller's credential, never from params.
  """
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Portal.{UsageAccount, UsageSnapshot}
  alias FirstmatePort.{Tenancy, Usage}
  alias FirstmatePort.Usage.Sync

  def index(conn, _params) do
    actor = conn.assigns.current_user
    opts = Tenancy.opts(actor)

    with {:ok, accounts} <- UsageAccount.list(opts) do
      data =
        accounts
        |> Usage.sort_for_spend()
        |> Enum.map(fn account ->
          {:ok, snaps} = UsageSnapshot.for_account(account.id, opts)
          Usage.summarize(account, snaps)
        end)

      json(conn, %{tenant: Tenancy.slug(actor), data: data})
    else
      {:error, error} ->
        conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  def create(conn, params) do
    actor = conn.assigns.current_user

    case UsageAccount.record(attrs(params), Tenancy.opts(actor)) do
      {:ok, account} ->
        {:ok, snaps} = UsageSnapshot.for_account(account.id, Tenancy.opts(actor))
        json(conn, Usage.summarize(account, snaps))

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
    end
  end

  def sync(conn, _params) do
    actor = conn.assigns.current_user

    case Sync.sync_all(actor) do
      {:ok, results} ->
        json(conn, %{
          tenant: Tenancy.slug(actor),
          data:
            Enum.map(results, fn %{account: account, synced?: synced?, note: note} ->
              %{account: Usage.summarize(account), synced: synced?, note: note}
            end)
        })

      {:error, error} ->
        conn |> put_status(:forbidden) |> json(%{error: inspect(error)})
    end
  end

  defp attrs(params) do
    %{
      provider: params["provider"],
      label: params["label"] || params["provider"],
      unit: one_of(params["unit"], ~w(usd tokens credits), "usd"),
      allowance: number(params["allowance"]),
      used: number(params["used"]) || 0.0,
      window: one_of(params["window"], ~w(monthly weekly daily one_time), "monthly"),
      spend_priority: integer(params["spend_priority"]) || 100,
      source: :manual,
      reset_at: datetime(params["reset_at"]),
      notes: params["notes"] || ""
    }
  end

  defp one_of(value, allowed, default) do
    if value in allowed, do: String.to_atom(value), else: String.to_atom(default)
  end

  defp number(nil), do: nil
  defp number(n) when is_number(n), do: n * 1.0

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp integer(nil), do: nil
  defp integer(i) when is_integer(i), do: i

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp datetime(nil), do: nil

  defp datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
