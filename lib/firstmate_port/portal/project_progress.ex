defmodule FirstmatePort.Portal.ProjectProgress do
  @moduledoc false
  use Ash.Resource.Preparation
  require Ash.Query

  @fields [:kind, :title, :status, :assignee, :extra_workers, :interruption]

  @impl true
  def prepare(query, _opts, context) do
    Ash.Query.after_action(query, fn _query, items ->
      ids = Enum.map(items, & &1.id)

      events =
        FirstmatePort.Portal.ProgressEvent
        |> Ash.Query.filter(item_id in ^ids)
        |> Ash.Query.sort(id: :asc)
        |> Ash.read(FirstmatePort.Tenancy.opts(context.actor))

      with {:ok, events} <- events do
        by_item = Enum.group_by(events, & &1.item_id)

        {:ok,
         Enum.map(items, fn item ->
           Enum.reduce(Map.get(by_item, item.id, []), item, fn event, state ->
             patch =
               event |> Map.take(@fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)

             state |> Map.merge(patch) |> Map.put(:updated_at, event.inserted_at)
           end)
         end)}
      end
    end)
  end
end
