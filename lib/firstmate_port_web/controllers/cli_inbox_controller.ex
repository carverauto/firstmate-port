defmodule FirstmatePortWeb.CliInboxController do
  @moduledoc "HTTP inbox port. fm-steer never dials NATS."
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Inbox
  alias FirstmatePort.Tenancy

  def put(conn, params) do
    case Inbox.put(slug(conn), params) do
      {:ok, item} -> json(conn, item)
      {:error, _} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid"})
    end
  end

  def next(conn, params) do
    case Inbox.next(slug(conn), params["task"]) do
      {:ok, item} -> json(conn, item)
      :empty -> conn |> put_status(:no_content) |> text("")
    end
  end

  def ack(conn, params) do
    case Inbox.ack(slug(conn), params["ack"]) do
      :ok -> json(conn, %{ok: true})
      {:error, _} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def list(conn, params) do
    {:ok, items} = Inbox.list(slug(conn), params["task"])
    json(conn, %{data: items})
  end

  defp slug(conn), do: Tenancy.slug(conn.assigns.current_user)
end
