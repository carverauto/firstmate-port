defmodule FirstmatePort.Portal.ProjectProgressSubject do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn query, items ->
      with {:ok, subjects} <- load(Enum.map(items, & &1.id), query.tenant) do
        {:ok, Enum.map(items, &Map.merge(&1, Map.get(subjects, &1.id, %{})))}
      end
    end)
  end

  def load([], _tenant), do: {:ok, %{}}

  def load(ids, tenant) do
    with {:ok, %{rows: rows}} <-
           FirstmatePort.Repo.query(
             """
             SELECT DISTINCT ON (item_id) item_id, title, kind
             FROM progress_events
             WHERE tenant_slug = $1 AND item_id = ANY($2::text[]) AND type = 'subject'
             ORDER BY item_id, occurred_at DESC, inserted_at DESC, id DESC
             """,
             [tenant, ids]
           ) do
      {:ok,
       Map.new(rows, fn [id, title, kind] ->
         {id, %{title: title, kind: String.to_existing_atom(kind)}}
       end)}
    end
  end
end
