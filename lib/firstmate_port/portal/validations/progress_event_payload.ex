defmodule FirstmatePort.Portal.Validations.ProgressEventPayload do
  @moduledoc """
  Holds each fleet-log event type to the field that gives it meaning, so the
  projection never has to guess. A `:status` event without a status, or a
  `:contribution` without a worker, would silently drop out of the details view
  and skew the charts; both are rejected at append time instead.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :type) do
      :subject ->
        with :ok <- require_field(changeset, :title, "is required on a :subject event"),
             :ok <- require_field(changeset, :kind, "is required on a :subject event") do
          validate_subject(changeset, context)
        end

      :status ->
        require_field(changeset, :status, "is required on a :status event")

      :assignment ->
        require_worker(changeset, ":assignment")

      :contribution ->
        require_worker(changeset, ":contribution")

      :interruption ->
        require_field(changeset, :interrupted, "is required on an :interruption event")

      :note ->
        require_detail(changeset)

      _ ->
        :ok
    end
  end

  defp validate_subject(changeset, context) do
    opts = [actor: context.actor, tenant: changeset.tenant]
    item_id = Ash.Changeset.get_attribute(changeset, :item_id)
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    with {:ok, item} when not is_nil(item) <-
           FirstmatePort.Portal.ProgressItem.get_by_id(item_id, opts),
         {:ok, _} <- FirstmatePort.Links.progress_url(to_string(kind), item.url) do
      :ok
    else
      _ -> {:error, field: :item_id, message: "invalid progress item or kind"}
    end
  end

  defp require_field(changeset, field, message) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil -> {:error, field: field, message: message}
      _ -> :ok
    end
  end

  defp require_worker(changeset, type) do
    case Ash.Changeset.get_attribute(changeset, :worker) do
      worker when is_binary(worker) and worker != "" -> :ok
      _ -> {:error, field: :worker, message: "is required on a #{type} event"}
    end
  end

  defp require_detail(changeset) do
    case Ash.Changeset.get_attribute(changeset, :detail) do
      detail when is_binary(detail) and detail != "" -> :ok
      _ -> {:error, field: :detail, message: "is required on a :note event"}
    end
  end
end
