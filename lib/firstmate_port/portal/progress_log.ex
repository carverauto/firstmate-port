defmodule FirstmatePort.Portal.ProgressLog do
  @moduledoc """
  The write side of the fleet log. Every function here appends; none of them
  update or delete.

  `record_status/4` is the one producers should reach for when they are polling
  rather than reporting: it reads the current projection first and appends only
  when the status actually moved, so a poll that runs every few minutes does not
  fill the log with a hundred identical "still in progress" rows.
  """

  require Ash.Query

  alias FirstmatePort.Portal.{ProgressEvent, ProgressItem, ProgressProjection, ProgressStatus}

  @doc "Appends one event verbatim."
  def append(attrs, opts), do: ProgressEvent.append(attrs, opts)

  @doc """
  Appends a `:status` event only when it differs from the item's current
  projected status.

  Returns `{:ok, :appended, event}`, `{:ok, :unchanged, status}`, or
  `{:error, reason}`.
  """
  def record_status(item, status, extra \\ %{}, opts) do
    do_record_status(item, status, extra, opts, fn _projection, _observed -> :allow end)
  end

  @doc """
  The GitHub poll's way in. Same as `record_status/4`, but it will not drag a
  crew judgement backwards.

  The poll can see that a pull request merged or an issue closed, and that
  always wins. It cannot tell "draft" from "ready for review" from "stalled" —
  they all look open to the search API — so an observed `:in_progress` is
  dropped whenever the crew has already said something more specific.

  Returns `{:ok, :ignored, status}` in that case.
  """
  def record_observed_status(item, status, extra \\ %{}, opts) do
    with {:ok, canonical} <- ProgressStatus.parse(status),
         {:ok, recorded?} <- observed_transition?(item, canonical, Map.new(extra), opts) do
      if recorded? do
        {:ok, :unchanged, canonical}
      else
        do_record_status(item, canonical, extra, opts, fn projection, observed ->
          if ProgressStatus.github_may_report?(observed, current_status(projection)),
            do: :allow,
            else: :ignore
        end)
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

  defp do_record_status(item, status, extra, opts, gate) do
    with {:ok, status} <- ProgressStatus.parse(status),
         {:ok, [projection]} <- ProgressProjection.load([item], opts) do
      case gate.(projection, status) do
        :ignore ->
          {:ok, :ignored, status}

        :allow ->
          if projection.status == status and projection.status_source == :log do
            {:ok, :unchanged, status}
          else
            attrs =
              extra
              |> Map.new()
              |> Map.merge(%{item_id: item.id, type: :status, status: status})

            case append(attrs, opts) do
              {:ok, event} -> {:ok, :appended, event}
              {:error, error} -> {:error, error}
            end
          end
      end
    else
      :error -> {:error, :invalid_status}
      {:error, error} -> {:error, error}
    end
  end

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

