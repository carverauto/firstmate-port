defmodule FirstmatePort.Portal.Assignment do
  @moduledoc "Applies firstmate assignment messages from JetStream onto GithubItem rows."

  alias FirstmatePort.Portal.GithubItem

  def apply(%{"pr_url" => url} = map) when is_binary(url) and url != "" do
    apply_url(url, map)
  end

  def apply(%{"issue_url" => url} = map) when is_binary(url) and url != "" do
    apply_url(url, map)
  end

  def apply(_), do: :ok

  defp apply_url(url, map) do
    actor = %{
      role: :agent,
      email: "agent@localhost",
      tenant_slug: Map.get(map, "tenant_slug") || FirstmatePort.Tenancy.default_slug()
    }

    case GithubItem.list(FirstmatePort.Tenancy.opts(actor)) do
      {:ok, items} ->
        Enum.each(items, fn item ->
          if item.html_url == url do
            GithubItem.assign(
              item,
              %{
                assignment_task_id: map["task_id"] || map["task"],
                assignment_worker: map["worker"],
                assignment_status: map["status"]
              },
              FirstmatePort.Tenancy.opts(actor)
            )
          end
        end)

      _ ->
        :ok
    end
  end
end
