defmodule FirstmatePort.Security.Lockouts do
  @moduledoc """
  Locks an account out after repeated failed sign-ins, across source
  addresses.

  The rate limiter in `FirstmatePort.Security.RateLimiter` keys on the client
  address, so it stops one host hammering one endpoint. It does nothing about
  a spray that spends one attempt per address against the same account. This
  module keys on the account instead: every failed sign-in for
  `captain@example.com` counts toward the same total no matter where it came
  from, and crossing the threshold shuts that account's sign-in path for
  `lock_seconds`.

  Serviceradar persists the equivalent state as Ash resources
  (`ServiceRadar.Security.AuthLockout` + a `SecurityEvent` stream). The portal
  keeps it in node-local ETS instead: no migration, no new resource, and no
  audit table to keep pruned. The tradeoff is that a restart clears active
  lockouts, so a patient attacker who can wait out a deploy gets a fresh
  budget. Given a single-replica deployment and a threshold measured in
  minutes, that is the cheaper side of the trade — revisit it if the portal
  ever grows a real audit UI.

  Configure with:

      config :firstmate_port, FirstmatePort.Security.Lockouts,
        threshold: 10,
        window_seconds: 900,
        lock_seconds: 900

  Failures are recorded by the sign-in paths themselves
  (`FirstmatePortWeb.AuthController`); `FirstmatePortWeb.Plugs.LockoutCheck`
  is what refuses the request while a lockout is active.
  """

  use GenServer

  require Logger

  @table :firstmate_port_security_lockouts
  @cleanup_interval :timer.minutes(5)

  @default_threshold 10
  @default_window_seconds 900
  @default_lock_seconds 900

  @type actor_key :: String.t()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Normalizes an account identifier so `Captain@Example.com ` and
  `captain@example.com` count as the same account.
  """
  @spec actor_key(term()) :: actor_key() | nil
  def actor_key(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      key -> key
    end
  end

  def actor_key(nil), do: nil
  def actor_key(value), do: value |> to_string() |> actor_key()

  @doc """
  Records one failed sign-in for `actor` and opens a lockout when the
  threshold is crossed.

  Returns `:ok`, or `{:locked, expires_at}` when this failure tripped (or hit)
  the lock. `metadata` is only used for the log line.
  """
  @spec record_failed_login(term(), map()) :: :ok | {:locked, DateTime.t()}
  def record_failed_login(actor, metadata \\ %{}) do
    case actor_key(actor) do
      nil -> :ok
      key -> GenServer.call(__MODULE__, {:record_failure, key, metadata})
    end
  catch
    :exit, _reason -> :ok
  end

  @doc "Clears failures and any active lockout for `actor` after a successful sign-in."
  @spec clear(term()) :: :ok
  def clear(actor) do
    case actor_key(actor) do
      nil -> :ok
      key -> GenServer.call(__MODULE__, {:clear, key})
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the expiry of `actor`'s active lockout, or `nil` when the account is
  free to try again.
  """
  @spec active_lockout(term()) :: DateTime.t() | nil
  def active_lockout(actor) do
    with key when is_binary(key) <- actor_key(actor),
         [{^key, _failures, locked_until}] <- lookup(key),
         true <- locked_until != nil,
         :lt <- DateTime.compare(DateTime.utc_now(), locked_until) do
      locked_until
    else
      _ -> nil
    end
  end

  @doc "Current lockout policy as `{threshold, window_seconds, lock_seconds}`."
  @spec policy() :: {pos_integer(), pos_integer(), pos_integer()}
  def policy do
    config = Application.get_env(:firstmate_port, __MODULE__) || []

    {
      Keyword.get(config, :threshold, @default_threshold),
      Keyword.get(config, :window_seconds, @default_window_seconds),
      Keyword.get(config, :lock_seconds, @default_lock_seconds)
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
  def handle_call({:record_failure, key, metadata}, _from, state) do
    {threshold, window_seconds, lock_seconds} = policy()
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -window_seconds, :second)
    {previous_failures, locked_until} = current_state(key, now)

    failures = [now | Enum.filter(previous_failures, &(DateTime.compare(&1, cutoff) != :lt))]

    cond do
      locked_until != nil ->
        :ets.insert(@table, {key, failures, locked_until})
        {:reply, {:locked, locked_until}, state}

      length(failures) >= threshold ->
        expires_at = DateTime.add(now, lock_seconds, :second)
        :ets.insert(@table, {key, failures, expires_at})
        report_lockout(key, failures, expires_at, metadata)
        {:reply, {:locked, expires_at}, state}

      true ->
        :ets.insert(@table, {key, failures, nil})
        {:reply, :ok, state}
    end
  end

  def handle_call({:clear, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    {_threshold, window_seconds, _lock_seconds} = policy()
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -window_seconds, :second)

    :ets.foldl(
      fn {key, failures, locked_until}, :ok ->
        kept = Enum.filter(failures, &(DateTime.compare(&1, cutoff) != :lt))

        if kept == [] and not active?(locked_until, now) do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, kept, locked_until})
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

  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  # An expired lockout starts the account over. Without the reset, the failures
  # that caused the lock are still inside the counting window when it lifts, so
  # the first honest typo after serving the wait locks the account again.
  defp current_state(key, now) do
    case lookup(key) do
      [{^key, failures, nil}] ->
        {failures, nil}

      [{^key, failures, locked_until}] ->
        if active?(locked_until, now), do: {failures, locked_until}, else: {[], nil}

      [] ->
        {[], nil}
    end
  end

  defp report_lockout(key, failures, expires_at, metadata) do
    Logger.warning(
      "security: locked sign-in for #{redact(key)} until #{DateTime.to_iso8601(expires_at)} " <>
        "after #{length(failures)} failures#{route_suffix(metadata)}"
    )

    :telemetry.execute(
      [:firstmate_port, :security, :lockout, :triggered],
      %{failures: length(failures)},
      %{expires_at: expires_at, route: Map.get(metadata, :route)}
    )
  end

  defp active?(nil, _now), do: false
  defp active?(locked_until, now), do: DateTime.compare(now, locked_until) == :lt

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)

  defp route_suffix(%{route: route}) when is_binary(route), do: " on #{route}"
  defp route_suffix(_metadata), do: ""

  # Log which account tripped without writing a full address into the logs.
  defp redact(key) do
    case String.split(key, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 2) <> "***@" <> domain
      [only] -> String.slice(only, 0, 2) <> "***"
    end
  end
end
