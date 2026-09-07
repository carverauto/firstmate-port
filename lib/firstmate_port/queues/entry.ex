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
  already tracked. See `docs/queues.md` for report freshness and counter semantics.
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
    :updated_at,
    defaulted_fields: []
  ]

  @type t :: %__MODULE__{}

  @doc "The schema tag stamped on every payload published to JetStream."
  def schema, do: @schema

  @doc "Statuses a worker may report."
  def statuses, do: @statuses

  @doc "True once the work has stopped and only retention keeps the row visible."
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc """
  Validates and normalizes an inbound report into a sparse entry. Missing, null,
  and blank text values remain unset; reports cannot explicitly clear fields.
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def new(tenant_slug, params) when is_map(params) do
    params = stringify(params)

    with {:ok, task} <- required(params, "task", :missing_task),
         {:ok, worker} <- text(params["worker"]),
         {:ok, agent_id} <- text(params["agent_id"]),
         {:ok, model} <- text(params["model"]),
         {:ok, effort} <- text(params["effort"]),
         {:ok, summary} <- text(params["summary"]),
         {:ok, status} <- status(params["status"]),
         {:ok, tokens_in} <- tokens(params["tokens_in"]),
         {:ok, tokens_out} <- tokens(params["tokens_out"]),
         {:ok, started_at} <- timestamp(params["started_at"]),
         {:ok, stopped_at} <- timestamp(params["stopped_at"]),
         {:ok, updated_at} <- timestamp(params["updated_at"]) do
      {:ok,
       %__MODULE__{
         task: task,
         tenant_slug: FirstmatePort.Tenancy.slug(tenant_slug),
         worker: worker,
         agent_id: agent_id,
         model: model,
         effort: effort,
         summary: summary,
         status: status,
         tokens_in: tokens_in,
         tokens_out: tokens_out,
         started_at: started_at,
         stopped_at: stopped_at,
         updated_at: updated_at
       }}
    end
  end

  def new(_tenant_slug, _params), do: {:error, :invalid_report}

  @doc """
  Folds a report onto the tracked entry. Passing `nil` seeds a new one, which is
  where the defaults (queued, zero tokens, started now) come from.
  """
  @spec merge(t() | nil, t()) :: t()
  def merge(nil, %__MODULE__{} = update) do
    %__MODULE__{} = update = reported(update)
    at = update.updated_at || DateTime.utc_now()

    settle(%__MODULE__{
      update
      | status: update.status || :queued,
        tokens_in: update.tokens_in || 0,
        tokens_out: update.tokens_out || 0,
        started_at: update.started_at || at,
        updated_at: at,
        defaulted_fields: Enum.filter([:status, :started_at], &is_nil(Map.fetch!(update, &1)))
    })
  end

  def merge(%__MODULE__{} = prior, %__MODULE__{} = update) do
    %__MODULE__{} = update = reported(update)
    at = update.updated_at || DateTime.utc_now()

    prior = %{
      prior
      | tokens_in: high_water(prior.tokens_in, update.tokens_in),
        tokens_out: high_water(prior.tokens_out, update.tokens_out)
    }

    if DateTime.compare(at, prior.updated_at) == :lt do
      prior
    else
      settle(%__MODULE__{
        prior
        | worker: update.worker || prior.worker,
          agent_id: update.agent_id || prior.agent_id,
          model: update.model || prior.model,
          effort: update.effort || prior.effort,
          summary: update.summary || prior.summary,
          status: update.status || prior.status,
          started_at: update.started_at || prior.started_at,
          stopped_at: update.stopped_at || prior.stopped_at,
          updated_at: at,
          defaulted_fields: Enum.filter(prior.defaulted_fields, &is_nil(Map.fetch!(update, &1)))
      })
    end
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
  The display form: string keys and ISO8601 timestamps, including local defaults.
  Use `to_report/1` for publication so defaults do not become reported facts.
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

  @doc "The normalized wire report, excluding locally seeded status and start time."
  @spec to_report(t()) :: map()
  def to_report(%__MODULE__{} = entry) do
    Map.drop(to_map(entry), Enum.map(entry.defaulted_fields, &Atom.to_string/1))
  end

  defp reported(%__MODULE__{} = entry) do
    Enum.reduce(entry.defaulted_fields, entry, &Map.put(&2, &1, nil))
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

  defp required(params, key, error) do
    with {:ok, value} <- text(Map.get(params, key)) do
      if is_nil(value), do: {:error, error}, else: {:ok, value}
    end
  end

  defp stringify(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp text(nil), do: {:ok, nil}

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp text(_), do: {:error, :invalid_text}

  defp status(nil), do: {:ok, nil}

  defp status(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase() |> String.replace("-", "_")

    case Enum.find(@statuses, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, :invalid_status}
      status -> {:ok, status}
    end
  end

  defp status(_), do: {:error, :invalid_status}

  defp tokens(nil), do: {:ok, nil}
  defp tokens(value) when is_integer(value) and value >= 0, do: {:ok, value}
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
