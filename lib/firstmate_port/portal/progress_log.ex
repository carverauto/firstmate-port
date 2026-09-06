defmodule FirstmatePort.Portal.ProgressLog do
  @moduledoc """
  The write side of the fleet log. Every function here appends; none of them
  update or delete.

  GitHub observations append only when the transition is new and the observed
  status may replace the crew's current judgement.
  """

  require Ash.Query

  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem, ProgressProjection, ProgressStatus}

  @doc "Appends one event verbatim."
  def append(attrs, opts), do: ProgressEvent.append(attrs, opts)

  @doc """
  Appends a new GitHub-observed status without replacing more specific crew
  judgements with an open state. Historical transitions already recorded at
  the observed timestamp are unchanged.

  Returns `{:ok, :appended, event}`, `{:ok, :unchanged, status}`,
  `{:ok, :ignored, status}`, or `{:error, reason}`.
  """
  def record_observed_status(item, status, extra \\ %{}, opts) do
    with {:ok, status} <- ProgressStatus.parse(status),
         {:ok, recorded?} <- observed_transition?(item, status, Map.new(extra), opts),
         {:ok, [projection]} <- ProgressProjection.load([item], opts) do
      cond do
        recorded? ->
          {:ok, :unchanged, status}

        not ProgressStatus.github_may_report?(status, current_status(projection)) ->
          {:ok, :ignored, status}

        projection.status == status and projection.status_source == :log ->
          {:ok, :unchanged, status}

        true ->
          attrs =
            extra
            |> Map.new()
            |> Map.merge(%{item_id: item.id, type: :status, status: status})

          case append(attrs, opts) do
            {:ok, event} -> {:ok, :appended, event}
            {:error, error} -> {:error, error}
          end
      end
    else
      :error -> {:error, :invalid_status}
      {:error, error} -> {:error, error}
    end
  end

  defp observed_transition?(item, status, %{occurred_at: at}, opts) when not is_nil(at) do
    ProgressEvent
    |> Ash.Query.filter(
      item_id == ^item.id and type == :status and status == ^status and occurred_at == ^at
    )
    |> Ash.exists(opts)
  end

  defp observed_transition?(_item, _status, _extra, _opts), do: {:ok, false}

  defp current_status(%{status_source: :log, status: status}), do: status
  defp current_status(_projection), do: nil

  @doc """
  Resolves the item an inbound event names, by portal id or by the GitHub URL
  the producer already has. Returns `{:error, :not_found}` rather than creating
  one, so a typo cannot silently fork a new fleet-log row.
  """
  def find_item(%{"item_id" => id}, opts) when is_binary(id) and id != "" do
    fetch_by_id(id, opts)
  end

  def find_item(%{"url" => url}, opts) when is_binary(url) and url != "" do
    case ProgressItem.get_by_url(url, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, item} -> {:ok, item}
      {:error, _} -> {:error, :not_found}
    end
  end

  def find_item(_params, _opts), do: {:error, :not_found}

  defp fetch_by_id(id, opts) do
    case ProgressItem.get_by_id(id, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, item} -> {:ok, item}
      {:error, _} -> {:error, :not_found}
    end
  end
end
