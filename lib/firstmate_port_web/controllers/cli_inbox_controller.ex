defmodule FirstmatePortWeb.CliInboxController do
  @moduledoc """
  HTTP inbox port for `fm-steer`. The CLI never dials NATS.

  Every action runs as the signed-in user, so the store records which mate filed
  a message and which one claimed it, and the tenant wall is the actor's own
  tenant rather than anything the request asked for.
  """
  use FirstmatePortWeb, :controller

  alias FirstmatePort.Inbox

  def put(conn, params) do
    case Inbox.put(actor(conn), params) do
      {:ok, item} -> json(conn, item)
      {:error, :invalid} -> unprocessable(conn, "body is required")
      {:error, _} -> unprocessable(conn, "invalid")
    end
  end

  def next(conn, params) do
    case Inbox.next(actor(conn), params["task"]) do
      {:ok, item} -> json(conn, item)
      :empty -> conn |> put_status(:no_content) |> text("")
      {:error, _} -> unprocessable(conn, "invalid")
    end
  end

  def ack(conn, params) do
    case Inbox.ack(actor(conn), params["ack"]) do
      {:ok, _acked} -> json(conn, %{ok: true})
      {:error, _} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def list(conn, params) do
    case Inbox.list(actor(conn), params["task"]) do
      {:ok, items} -> json(conn, %{data: items})
      {:error, _} -> unprocessable(conn, "invalid")
    end
  end

  defp actor(conn), do: conn.assigns.current_user

  defp unprocessable(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: message})
  end
end
