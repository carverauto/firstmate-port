defmodule FirstmatePortWeb.UsageController do
  @moduledoc """
  Portal-owned token usage / billing API. Every row is tenant-scoped;
  the tenant comes from the caller's credential, never from params.
  """
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Portal.UsageAccount
  alias FirstmatePort.{Tenancy, Usage}
  alias FirstmatePort.Usage.BurnWindow

  def index(conn, _params) do
    actor = conn.assigns.current_user
    opts = Tenancy.opts(actor)

    with {:ok, accounts} <- UsageAccount.list(opts) do
      data =
        accounts
        |> Usage.sort_for_spend()
        |> Enum.map(&Usage.summarize(&1, BurnWindow.for_account(&1.id, Tenancy.slug(actor))))

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
        json(
          conn,
          Usage.summarize(account, BurnWindow.for_account(account.id, Tenancy.slug(actor)))
        )

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(error)})
    end
  end

  defp attrs(params) do
    %{provider: params["provider"], label: params["label"] || params["provider"]}
    |> put_given(:unit, one_of(params["unit"], ~w(usd tokens credits)))
    |> put_given(:allowance, number(params["allowance"]))
    |> put_given(:used, number(params["used"]))
    |> put_given(:window, one_of(params["window"], ~w(monthly weekly daily one_time)))
    |> put_given(:spend_priority, integer(params["spend_priority"]))
  end

  defp put_given(attrs, _key, nil), do: attrs
  defp put_given(attrs, key, value), do: Map.put(attrs, key, value)

  defp one_of(value, allowed) do
    if value in allowed, do: String.to_atom(value), else: nil
  end

  defp number(nil), do: nil
  defp number(n) when is_number(n), do: n * 1.0

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp number(_), do: nil

  defp integer(nil), do: nil
  defp integer(i) when is_integer(i), do: i

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp integer(_), do: nil
end
