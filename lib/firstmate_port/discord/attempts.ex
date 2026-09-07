defmodule FirstmatePort.Discord.Attempts do
  @moduledoc """
  The last few inbound Discord interactions and what the endpoint did with them.

  Tenant-scoped diagnostics for `/settings/credentials`. Response semantics and
  operator guidance live in `docs/credentials.md`, "Discord inbound".

  Deliberately not a resource, on the same terms as `FirstmatePort.Queues.Tracker`:
  it is a look-in at the last few minutes of an endpoint being set up, it is
  capped, it ages out, and nothing here is the store of record. The audit trail
  of who stored which credential is `AshPaperTrail`'s, not this.

  Recording is a cast. Discord gives the endpoint three seconds and this is
  decoration - it must never be what makes a request slow, and it must never be
  what makes one fail.
  """

  use GenServer

  alias FirstmatePort.Tenancy

  @pubsub FirstmatePort.PubSub
  @topic "discord:attempts"

  @max_per_tenant 20
  @retain_ms :timer.hours(1)
  @sweep_ms :timer.minutes(5)

  @typedoc "What the endpoint did with one inbound interaction."
  @type outcome ::
          :pong
          | :published
          | :answered
          | :modal_opened
          | :captain_refused
          | :answer_not_recorded
          | :already_answered
          | :call_not_found
          | :invalid_answer
          | :no_signature
          | :stale_timestamp
          | :unreadable_body
          | :too_large
          | :no_key
          | :unreadable_key
          | :unusable_key
          | :malformed_signature
          | :bad_signature
          | :upstream_unavailable
          | :wrong_path

  # Ordered worst-cause-first only for reading; the map is what makes the log
  # line and the portal say the same thing about the same outcome.
  @descriptions %{
    pong: "PING verified - answered PONG",
    published: "verified - published to this tenant's inbound subject",
    answered: "verified - captain answer and inbox order recorded",
    modal_opened: "verified - answer modal opened; no answer recorded yet",
    captain_refused: "refused: clicker is not the configured captain",
    answer_not_recorded: "verified, but the answer and inbox order could not be recorded",
    already_answered: "verified - call already answered; no new order filed",
    call_not_found: "refused: question not found for this tenant",
    invalid_answer: "refused: missing choice or choice not offered by this question",
    no_signature: "refused: no X-Signature-Ed25519 header",
    stale_timestamp: "refused: timestamp missing, unparseable, or too far from now",
    unreadable_body:
      "refused: request body was never read - is the content type application/json?",
    too_large: "refused: body over the 64 KB cap",
    no_key: "refused: this tenant has no Discord public key stored",
    unreadable_key: "refused: a key is stored but the vault would not decrypt it",
    unusable_key: "refused: the stored key is not 64 hex characters",
    malformed_signature: "refused: signature header is not 64 bytes of hex",
    bad_signature: "refused: signature did not verify against the stored key",
    upstream_unavailable: "verified, but the message could not be queued",
    wrong_path: "refused: reached the interactions hostname at another path"
  }

  @typedoc "One recorded attempt."
  @type t :: %{
          at: DateTime.t(),
          outcome: outcome(),
          description: String.t(),
          verified?: boolean(),
          type: integer() | nil,
          application_id: String.t() | nil,
          skew_seconds: integer() | nil,
          path: String.t() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Notes what happened to one interaction for `tenant`.

  `meta` may carry `:type` (Discord's interaction type), `:application_id`,
  `:skew_seconds`, and `:path`. Never the signature, never the body, never the
  key.
  """
  @spec record(GenServer.server(), term(), outcome(), map()) :: :ok
  def record(server \\ __MODULE__, tenant, outcome, meta) do
    GenServer.cast(server, {:record, Tenancy.slug(tenant), outcome, meta, DateTime.utc_now()})
  catch
    # The endpoint answers Discord whether or not this process is alive.
    :exit, _reason -> :ok
  end

  @doc "The tenant's recent attempts, newest first."
  @spec list(GenServer.server(), term()) :: [t()]
  def list(server \\ __MODULE__, tenant) do
    GenServer.call(server, {:list, Tenancy.slug(tenant)})
  catch
    :exit, _reason -> []
  end

  @doc "What an outcome means, in the one wording the log and the portal share."
  @spec describe(outcome()) :: String.t()
  def describe(outcome), do: Map.get(@descriptions, outcome, to_string(outcome))

  @doc "Whether an outcome means the signature check passed."
  @spec verified?(outcome()) :: boolean()
  def verified?(outcome),
    do:
      outcome in [
        :pong,
        :published,
        :answered,
        :modal_opened,
        :captain_refused,
        :answer_not_recorded,
        :already_answered,
        :call_not_found,
        :invalid_answer,
        :upstream_unavailable
      ]

  @doc "PubSub topic carrying `{:discord_attempt, attempt}`."
  def topic(tenant), do: @topic <> ":" <> Tenancy.slug(tenant)

  @impl true
  def init(opts) do
    sweep_ms = Keyword.get(opts, :sweep_ms, @sweep_ms)
    schedule_sweep(sweep_ms)
    {:ok, %{attempts: %{}, sweep_ms: sweep_ms}}
  end

  @impl true
  def handle_cast({:record, tenant, outcome, meta, at}, state) do
    attempt = %{
      at: at,
      outcome: outcome,
      description: describe(outcome),
      verified?: verified?(outcome),
      type: meta[:type],
      application_id: meta[:application_id],
      skew_seconds: meta[:skew_seconds],
      path: meta[:path]
    }

    kept =
      state.attempts
      |> Map.get(tenant, [])
      |> then(&Enum.take([attempt | &1], @max_per_tenant))

    Phoenix.PubSub.broadcast(@pubsub, topic(tenant), {:discord_attempt, attempt})

    {:noreply, %{state | attempts: Map.put(state.attempts, tenant, kept)}}
  end

  @impl true
  def handle_call({:list, tenant}, _from, state) do
    {:reply, fresh(Map.get(state.attempts, tenant, []), DateTime.utc_now()), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_ms)
    now = DateTime.utc_now()

    attempts =
      state.attempts
      |> Enum.map(fn {tenant, list} -> {tenant, fresh(list, now)} end)
      |> Enum.reject(fn {_tenant, list} -> list == [] end)
      |> Map.new()

    {:noreply, %{state | attempts: attempts}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp fresh(attempts, now) do
    Enum.filter(attempts, &(DateTime.diff(now, &1.at, :millisecond) < @retain_ms))
  end

  defp schedule_sweep(ms), do: Process.send_after(self(), :sweep, ms)
end
