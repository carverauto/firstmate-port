defmodule FirstmatePort.Queues.Entry do
  @moduledoc """
  One unit of crew work as the Queues look-in sees it: what was sent, which
  worker took it, the agent id, the model and effort it runs at, token usage,
  and the start/stop times.

  Entries are ephemeral. They live in `FirstmatePort.Queues.Tracker` memory and
  are never written to Postgres — the fleet log is the store of record, this is
  the present tense.

  Every field except the task is optional on any single report, so a worker can
  send what it knows when it knows it. `merge/2` folds a report onto what is
  already tracked: absent fields keep their prior value and the token counters
  only ever climb, which makes a duplicate delivery from JetStream a no-op.
  """

  @schema "fm-queue-entry.v1"

  @statuses ~w(queued working needs_decision blocked paused done failed)a
  @terminal ~w(done failed)a

  defstruct [
    :task,
    :tenant_slug,
    :worker,
    :agent_id,
    :model,
    :effort,
    :summary,
    :status,
    :tokens_in,
    :tokens_out,
    :started_at,
    :stopped_at,
    :updated_at
  ]

  @type t :: %__MODULE__{}

  @doc "The schema tag stamped on every payload published to JetStream."
  def schema, do: @schema

  @doc "Statuses a worker may report, in the order the UI ranks them."
  def statuses, do: @statuses

  @doc "True once the work has stopped and only retention keeps the row visible."
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc """
  Normalizes an inbound report into a sparse entry: only the fields the report
  actually carried are set, so `merge/2` can tell "unchanged" from "cleared".
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def new(tenant_slug, params) when is_map(params) do
    params = stringify(params)

    with {:ok, task} <- required(params, ["task", "task_id", "id"], :missing_task),
         {:ok, status} <- status(get(params, ["status"])),
         {:ok, tokens_in} <- tokens(get(params, ["tokens_in", "input_tokens"])),
         {:ok, tokens_out} <- tokens(get(params, ["tokens_out", "output_tokens"])),
         {:ok, started_at} <- timestamp(get(params, ["started_at"])),
         {:ok, stopped_at} <- timestamp(get(params, ["stopped_at"])),
         {:ok, updated_at} <- timestamp(get(params, ["updated_at", "at"])) do
      {:ok,
       %__MODULE__{
         task: task,
         tenant_slug: FirstmatePort.Tenancy.slug(tenant_slug),
         worker: get(params, ["worker"]),
         agent_id: get(params, ["agent_id", "agent"]),
         model: get(params, ["model"]),
         effort: get(params, ["effort"]),
         summary: get(params, ["summary"]),
         status: status,
         tokens_in: tokens_in,
         tokens_out: tokens_out,
         started_at: started_at,
         stopped_at: stopped_at,
         updated_at: updated_at
       }}
    end
  end

  @doc """
  Folds a report onto the tracked entry. Passing `nil` seeds a new one, which is
  where the defaults (queued, zero tokens, started now) come from.
  """
  @spec merge(t() | nil, t()) :: t()
  def merge(nil, %__MODULE__{} = update) do
    at = update.updated_at || DateTime.utc_now()

    settle(%__MODULE__{
      update
      | status: update.status || :queued,
        tokens_in: update.tokens_in || 0,
        tokens_out: update.tokens_out || 0,
        started_at: update.started_at || at,
        updated_at: at
    })
  end

  def merge(%__MODULE__{} = prior, %__MODULE__{} = update) do
    settle(%__MODULE__{
      prior
      | worker: update.worker || prior.worker,
        agent_id: update.agent_id || prior.agent_id,
        model: update.model || prior.model,
        effort: update.effort || prior.effort,
        summary: update.summary || prior.summary,
        status: update.status || prior.status,
        tokens_in: high_water(prior.tokens_in, update.tokens_in),
        tokens_out: high_water(prior.tokens_out, update.tokens_out),
        started_at: update.started_at || prior.started_at,
        stopped_at: update.stopped_at || prior.stopped_at,
        updated_at: latest(prior.updated_at, update.updated_at || DateTime.utc_now())
    })
  end

  @doc "Input plus output tokens, the number the look-in shows per row."
  def tokens_total(%__MODULE__{tokens_in: tokens_in, tokens_out: tokens_out}) do
    (tokens_in || 0) + (tokens_out || 0)
  end

  @doc """
  Wall-clock milliseconds the work has been running, measured to `now` while it
  is still in flight and to the stop time once it has finished.
  """
  def duration_ms(entry, now \\ nil)

  def duration_ms(%__MODULE__{started_at: nil}, _now), do: nil

  def duration_ms(%__MODULE__{started_at: started} = entry, now) do
    finish = entry.stopped_at || now || DateTime.utc_now()
    max(DateTime.diff(finish, started, :millisecond), 0)
  end

  @doc """
  The wire form: string keys and ISO8601 timestamps. Publishing the normalized
  entry rather than the raw request is what keeps a round trip through JetStream
  idempotent — the node that recorded it merges its own message back to itself.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      "schema" => @schema,
      "task" => entry.task,
      "tenant" => entry.tenant_slug,
      "worker" => entry.worker,
      "agent_id" => entry.agent_id,
      "model" => entry.model,
      "effort" => entry.effort,
      "summary" => entry.summary,
      "status" => entry.status && Atom.to_string(entry.status),
      "tokens_in" => entry.tokens_in,
      "tokens_out" => entry.tokens_out,
      "tokens_total" => tokens_total(entry),
      "started_at" => iso(entry.started_at),
      "stopped_at" => iso(entry.stopped_at),
      "updated_at" => iso(entry.updated_at)
    }
  end

  # A terminal report stops the clock; resuming a task clears the stop again so
  # the look-in shows it running rather than frozen at its old finish time.
  defp settle(%__MODULE__{} = entry) do
    cond do
      terminal?(entry) and is_nil(entry.stopped_at) -> %{entry | stopped_at: entry.updated_at}
      terminal?(entry) -> entry
      true -> %{entry | stopped_at: nil}
    end
  end

  defp high_water(prior, nil), do: prior
  defp high_water(nil, update), do: update
  defp high_water(prior, update), do: max(prior, update)

  defp latest(nil, other), do: other
  defp latest(other, nil), do: other

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp required(params, keys, error) do
    case get(params, keys) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp get(params, keys) do
    Enum.find_value(keys, fn key -> params |> Map.get(key) |> clean() end)
  end

  # Reports arrive as JSON from the API and as keyword-ish maps from tests, and
  # `String.to_existing_atom/1` on an alias we never allocated would raise, so
  # the atom keys are folded to strings before anything reads them.
  defp stringify(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp clean(value) when is_integer(value), do: value
  defp clean(%DateTime{} = value), do: value
  defp clean(_), do: nil

  defp status(nil), do: {:ok, nil}

  defp status(value) when is_binary(value) do
    normalized = value |> String.downcase() |> String.replace("-", "_")

    case Enum.find(@statuses, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, :invalid_status}
      status -> {:ok, status}
    end
  end

  defp tokens(nil), do: {:ok, nil}
  defp tokens(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp tokens(value) when is_integer(value), do: {:error, :invalid_tokens}

  defp tokens(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> {:ok, count}
      _ -> {:error, :invalid_tokens}
    end
  end

  defp tokens(_), do: {:error, :invalid_tokens}

  defp timestamp(nil), do: {:ok, nil}
  defp timestamp(%DateTime{} = value), do: {:ok, value}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp(_), do: {:error, :invalid_timestamp}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
