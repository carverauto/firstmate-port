defmodule FirstmatePort.Usage.Sync do
  @moduledoc """
  Syncs usage accounts from live provider APIs. Only providers with a
  configured API token are contacted, and tokens are read from the
  environment at runtime — they never touch git, chat, or the database.

  v1 syncs OpenRouter key usage (`OPENROUTER_API_KEY`, `GET
  /api/v1/key` → `%{"data" => %{"limit" => ..., "usage" => ...}}`).
  Every other provider is recorded manually or posted by agents until its
  API exposes per-account spend. Artificial Analysis sells benchmarks, not
  spend, so it stays routing intel only.
  """

  @openrouter_key_url "https://openrouter.ai/api/v1/key"

  @doc """
  Sync every syncable account visible to `actor`. Returns
  `{:ok, [%{account:, synced?:, note:}]}`. Never raises on provider
  errors: failures come back as `synced?: false` with the reason.
  """
  def sync_all(actor, opts \\ []) do
    tenant_opts = FirstmatePort.Tenancy.opts(actor)

    with {:ok, accounts} <- FirstmatePort.Portal.UsageAccount.list(tenant_opts) do
      results = Enum.map(accounts, &sync_account(&1, tenant_opts, opts))
      {:ok, results}
    end
  end

  @doc "Sync one account. `opts[:http]` injects the HTTP client (tests)."
  def sync_account(account, tenant_opts, opts \\ [])

  def sync_account(%{provider: "openrouter"} = account, tenant_opts, opts) do
    http = Keyword.get(opts, :http, &default_http/1)

    case System.get_env("OPENROUTER_API_KEY") do
      nil -> not_synced(account, "OPENROUTER_API_KEY is not configured")
      "" -> not_synced(account, "OPENROUTER_API_KEY is not configured")
      key -> apply_openrouter(account, key, tenant_opts, http)
    end
  end

  def sync_account(account, _tenant_opts, _opts) do
    not_synced(account, "no live sync for provider #{account.provider}; record usage manually")
  end

  @doc """
  Parse an OpenRouter key body into `%{limit:, usage:}`. Pure: safe to test.
  `limit: nil` means the key has no cap — allowance stays unknown.
  """
  def parse_openrouter_key(%{"data" => %{"usage" => usage} = data}) do
    {:ok, %{limit: Map.get(data, "limit"), usage: usage}}
  end

  def parse_openrouter_key(_), do: {:error, :unexpected_body}

  defp apply_openrouter(account, key, tenant_opts, http) do
    with {:ok, body} <- http.({@openrouter_key_url, [{"authorization", "Bearer #{key}"}]}),
         {:ok, %{limit: limit, usage: usage}} <- parse_openrouter_key(body),
         attrs <- refresh_attrs(usage, limit),
         {:ok, updated} <-
           FirstmatePort.Portal.UsageAccount.refresh(account, attrs, tenant_opts),
         {:ok, _snap} <-
           FirstmatePort.Portal.UsageSnapshot.record(
             %{usage_account_id: account.id, used: to_float(usage), source: :openrouter},
             tenant_opts
           ) do
      %{account: updated, synced?: true, note: "synced from OpenRouter key API"}
    else
      {:error, reason} -> not_synced(account, "openrouter sync failed: #{inspect(reason)}")
    end
  end

  # A nil provider limit means "no cap": keep any manual allowance instead
  # of overwriting it with unknown.
  defp refresh_attrs(usage, limit) do
    base = %{used: to_float(usage), source: :openrouter}

    case to_float(limit) do
      nil -> base
      cap -> Map.put(base, :allowance, cap)
    end
  end

  defp not_synced(account, note), do: %{account: account, synced?: false, note: note}

  defp default_http({url, headers}) do
    case Req.new(url: url, headers: headers, receive_timeout: 8_000) |> Req.get() do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _} = err -> err
    end
  rescue
    _ -> {:error, :http}
  end

  defp to_float(nil), do: nil
  defp to_float(f) when is_float(f), do: f
  defp to_float(i) when is_integer(i), do: i * 1.0

  defp to_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp to_float(_), do: nil
end
