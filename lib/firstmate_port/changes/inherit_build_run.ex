defmodule FirstmatePort.Changes.InheritBuildRun do
  @moduledoc """
  Copies a build run's context onto a later event in the same run.

  `fm-steer build finish` usually runs in a different shell from `start`, so it
  sends the run id, the outcome, and whatever it learned. The log is
  append-only - a finish event may not rewrite the start row - so the missing
  context is carried forward onto the new row instead, leaving each event
  self-describing.
  """

  use Ash.Resource.Change

  @inherited [
    :kind,
    :target,
    :agent_id,
    :model,
    :effort,
    :image,
    :image_tag,
    :cluster,
    :namespace,
    :started_at
  ]

  @impl true
  def change(changeset, _opts, context) do
    with run_id when is_binary(run_id) <- Ash.Changeset.get_attribute(changeset, :run_id),
         true <- Enum.any?(@inherited, &blank?(changeset, &1)),
         {:ok, [prior | _]} <- latest_event(changeset, run_id, context) do
      Enum.reduce(@inherited, changeset, &inherit(&2, &1, prior))
    else
      _ -> changeset
    end
  end

  defp inherit(changeset, field, prior) do
    value = Map.get(prior, field)

    if blank?(changeset, field) and not blank_value?(value) do
      Ash.Changeset.force_change_attribute(changeset, field, value)
    else
      changeset
    end
  end

  defp latest_event(changeset, run_id, context) do
    changeset.resource
    |> Ash.Query.for_read(:latest_for_run, %{run_id: run_id},
      actor: context.actor,
      authorize?: context.authorize?,
      tenant: context.tenant || changeset.tenant
    )
    |> Ash.read()
  end

  defp blank?(changeset, field) do
    changeset |> Ash.Changeset.get_attribute(field) |> blank_value?()
  end

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?(_), do: false
end
