defmodule FirstmatePort.Security.RateLimiter do
  @moduledoc """
  Sliding-window rate limiter for the public edge of the portal.

  Modelled on `ServiceRadar.Security.RateLimiter` but deliberately smaller:
  serviceradar spreads its counters across a libcluster/Horde BEAM cluster,
  and the portal has no cluster to spread across (`k8s/deployment.yaml` runs
  a single replica). Counters therefore live in one node-local ETS table and
  reset when the node restarts. Two consequences worth knowing before you
  scale the Deployment past one replica:

  * With N replicas an attacker gets N times the configured limit, because
    each replica counts only what it served. Put the edge limit in front of
    it — `deploy/examples/carverauto/portal-rate-limit-policy.yaml` is the
    Envoy `BackendTrafficPolicy` that does this for the public hostname.
  * A rolling restart forgives everything in flight. This limiter throttles
    bursts; `FirstmatePort.Security.Lockouts` is what survives a burst
    spread over an hour.

  Buckets are named and configured:

      config :firstmate_port, FirstmatePort.Security.RateLimiter,
        default_bucket: [limit: 120, window_seconds: 60],
        buckets: %{auth_local: [limit: 10, window_seconds: 60]}

  Defaults for every named bucket are compiled in below, so a deployment
  that configures nothing is still limited.
  """

  use GenServer

  @table :firstmate_port_security_rate_limiter
  @cleanup_interval :timer.minutes(5)
  @retention_seconds 86_400

  @default_bucket [limit: 120, window_seconds: 60]
  @buckets %{
    # Interactive sign-in. Low: a human types one password at a time.
    auth_local: [limit: 10, window_seconds: 60],
    # OIDC bounce-back. Higher than auth_local because a shared office NAT
    # can legitimately return several people at once.
    auth_oidc_callback: [limit: 30, window_seconds: 60],
    # RFC 8628 device authorization request.
    cli_device_auth: [limit: 30, window_seconds: 60],
    # RFC 8628 token polling: fm-steer polls every 5s per pending login, so
    # this has to tolerate several concurrent CLI logins behind one NAT.
    cli_token_poll: [limit: 120, window_seconds: 60],
    # Agent ingest writes (service-token gated, but publicly reachable).
    api_write: [limit: 120, window_seconds: 60],
    # Signed-in CLI/API traffic.
    api_default: [limit: 120, window_seconds: 60],
    # MCP tool calls.
    mcp: [limit: 120, window_seconds: 60],
    # Discord fans interactions out from many source addresses and expects an
    # answer inside 3s; this is a runaway-loop guard, not an access control.
    # The Ed25519 check in the controller is the access control.
    discord_interactions: [limit: 300, window_seconds: 60]
  }

  @type bucket :: atom()
  @type subject :: term()
  @type opts :: [limit: pos_integer(), window_seconds: pos_integer()]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Counts one attempt against `{bucket, subject}` and reports whether it is
  allowed.

  Returns `:ok`, or `{:error, retry_after_seconds}` when the window is full.
  A denied attempt is not counted, so a client hammering a full bucket does
  not extend its own penalty indefinitely.
  """
  @spec check_and_record(bucket(), subject(), opts()) :: :ok | {:error, pos_integer()}
  def check_and_record(bucket, subject, opts \\ []) do
    {limit, window} = resolve_bucket(bucket, opts)
    GenServer.call(__MODULE__, {:check_and_record, bucket, subject, limit, window})
  catch
    # The limiter is a supervised singleton; if it is restarting, serve the
    # request rather than 429-ing every caller during the restart window.
    :exit, _reason -> :ok
  end

  @doc "Drops the recorded attempts for `{bucket, subject}` (e.g. after a successful login)."
  @spec clear(bucket(), subject()) :: :ok
  def clear(bucket, subject) do
    GenServer.call(__MODULE__, {:clear, bucket, subject})
  catch
    :exit, _reason -> :ok
  end

  @doc "How many attempts remain in the current window for `{bucket, subject}`."
  @spec remaining(bucket(), subject(), opts()) :: non_neg_integer()
  def remaining(bucket, subject, opts \\ []) do
    {limit, window} = resolve_bucket(bucket, opts)
    now = System.system_time(:second)
    max(limit - length(attempts({bucket, subject}, now - window)), 0)
  rescue
    ArgumentError -> 0
  end

  @doc "Returns the oldest in-window attempt's expiry as an epoch second, or now plus the window."
  @spec reset_at(bucket(), subject(), opts()) :: integer()
  def reset_at(bucket, subject, opts \\ []) do
    {_limit, window} = resolve_bucket(bucket, opts)
    now = System.system_time(:second)

    try do
      reset_from_attempts(attempts({bucket, subject}, now - window), window, now)
    rescue
      ArgumentError -> now + window
    end
  end

  @doc "Returns `{limit, window_seconds}` for `bucket`, with `opts` overriding config."
  @spec resolve_bucket(bucket(), opts()) :: {pos_integer(), pos_integer()}
  def resolve_bucket(bucket, opts \\ []) do
    config = Application.get_env(:firstmate_port, __MODULE__) || []
    default = Keyword.get(config, :default_bucket, @default_bucket)

    configured =
      @buckets
      |> Map.merge(config |> Keyword.get(:buckets, %{}) |> normalize_buckets())
      |> Map.get(bucket, default)

    {
      Keyword.get(opts, :limit) || Keyword.get(configured, :limit, 120),
      Keyword.get(opts, :window_seconds) || Keyword.get(configured, :window_seconds, 60)
    }
  end

  @doc false
  def __table__, do: @table

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_and_record, bucket, subject, limit, window}, _from, state) do
    now = System.system_time(:second)
    key = {bucket, subject}
    recent = attempts(key, now - window)

    if length(recent) >= limit do
      reset = reset_from_attempts(recent, window, now)
      {:reply, {:error, max(reset - now, 1)}, state}
    else
      :ets.insert(@table, {key, [now | recent]})
      {:reply, :ok, state}
    end
  end

  def handle_call({:clear, bucket, subject}, _from, state) do
    :ets.delete(@table, {bucket, subject})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = System.system_time(:second) - @retention_seconds

    :ets.foldl(
      fn {key, timestamps}, :ok ->
        case Enum.filter(timestamps, &(&1 >= cutoff)) do
          [] -> :ets.delete(@table, key)
          kept -> :ets.insert(@table, {key, kept})
        end

        :ok
      end,
      :ok,
      @table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp attempts(key, window_start) do
    case :ets.lookup(@table, key) do
      [{^key, timestamps}] -> Enum.filter(timestamps, &(&1 >= window_start))
      [] -> []
    end
  end

  defp reset_from_attempts(recent, window, now) do
    Enum.min(recent, fn -> now end) + window
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)

  defp normalize_buckets(buckets) when is_map(buckets), do: buckets
  defp normalize_buckets(buckets) when is_list(buckets), do: Map.new(buckets)
  defp normalize_buckets(_other), do: %{}
end

