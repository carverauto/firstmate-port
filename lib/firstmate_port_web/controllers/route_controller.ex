defmodule FirstmatePortWeb.RouteController do
  @moduledoc """
  Portal-owned task routing API. Given a task description, returns the
  worker harness, model, and effort plus the reasons why. fm-steer calls
  this to pick a worker; the router never touches JetStream.

  The caller may override any classification axis (the rater-agent path:
  another agent ranks difficulty and the router still owns the lane pick).
  Pass `"intel": true` to fold in live OpenRouter / Artificial Analysis
  inputs; without it routing is fully offline on fleet matrix + evals.
  """
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Router
  alias FirstmatePort.Router.ProviderIntel
  alias FirstmatePort.Tenancy

  def create(conn, params) do
    description = text(params["description"]) || text(params["task"]) || ""

    if String.trim(description) == "" do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "description is required"})
    else
      intel = if params["intel"] in [true, "true"], do: ProviderIntel.fetch(), else: nil
      result = Router.route(description, axes: axes(params), intel: intel)

      json(
        conn,
        result
        |> Map.put(:axes, response_axes(result.axes))
        |> Map.put(:tenant, Tenancy.slug(conn.assigns.current_user))
      )
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil

  # Explicit string tables: no String.to_atom on request input, and no
  # dependency on another module having interned the atoms first.
  @axis_kinds %{
    "kind" => %{
      "code" => :code,
      "research" => :research,
      "ops" => :ops,
      "docs" => :docs,
      "review" => :review,
      "data" => :data,
      "chat" => :chat
    },
    "ambiguity" => %{"low" => :low, "medium" => :medium, "high" => :high},
    "blast_radius" => %{"low" => :low, "medium" => :medium, "high" => :high},
    "risk" => %{"low" => :low, "medium" => :medium, "high" => :high}
  }

  @axis_keys %{
    "kind" => :kind,
    "ambiguity" => :ambiguity,
    "blast_radius" => :blast_radius,
    "risk" => :risk
  }

  defp axes(%{"axes" => axes}) when is_map(axes) do
    Enum.reduce(@axis_kinds, %{}, fn {key, mapping}, acc ->
      case Map.get(axes, key) do
        value when is_binary(value) ->
          case Map.fetch(mapping, value) do
            {:ok, atom} -> Map.put(acc, Map.fetch!(@axis_keys, key), atom)
            :error -> acc
          end

        _ ->
          acc
      end
    end)
    |> put_bool(axes, "citations_required", :citations_required?)
    |> put_bool(axes, "live_web_required", :live_web_required?)
  end

  defp axes(_), do: %{}

  defp put_bool(acc, axes, param, target) do
    case Map.get(axes, param) do
      v when is_boolean(v) -> Map.put(acc, target, v)
      _ -> acc
    end
  end

  defp response_axes(axes) do
    axes
    |> Map.drop([:citations_required?, :live_web_required?])
    |> Map.put(:citations_required, axes.citations_required?)
    |> Map.put(:live_web_required, axes.live_web_required?)
  end
end
