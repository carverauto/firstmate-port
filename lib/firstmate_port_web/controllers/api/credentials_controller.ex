defmodule FirstmatePortWeb.Api.CredentialsController do
  @moduledoc """
  Tenant credential slots over HTTP, for `fm-steer` and anything else scripting
  the portal.

  Every response describes a secret without containing it: the slot, a hint
  (see `FirstmatePort.Credentials.Slots.hint/1`), and the byte size. There is no
  endpoint that reads a secret back, by design - a lost secret is rotated, not
  recovered.
  """

  use FirstmatePortWeb, :controller

  alias FirstmatePort.Credentials
  alias FirstmatePort.Credentials.{Credential, Errors, Slots}
  alias FirstmatePort.Tenancy

  def index(conn, _params) do
    case Credential.list(opts(conn)) do
      {:ok, rows} -> json(conn, %{data: Enum.map(rows, &summarize/1)})
      {:error, error} -> fail(conn, error)
    end
  end

  def slots(conn, _params) do
    json(conn, %{
      data:
        Enum.map(Slots.catalog(), fn slot ->
          %{provider: slot.provider, key: slot.key, label: slot.label, about: slot.about}
        end)
    })
  end

  def create(conn, params) do
    with {:ok, provider} <- slug(params["provider"], "provider"),
         {:ok, key} <- slug(params["key"], "key"),
         {:ok, value} <- secret(params["value"]) do
      attrs =
        %{provider: provider, key: key, value: value, description: ""}
        |> Map.merge(note(params))

      case Credential.create(attrs, opts(conn)) do
        {:ok, credential} -> conn |> put_status(:created) |> json(summarize(credential))
        {:error, error} -> fail(conn, error)
      end
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  def put(conn, %{"provider" => provider, "key" => key} = params) do
    with {:ok, provider} <- slug(provider, "provider"),
         {:ok, key} <- slug(key, "key"),
         {:ok, value} <- secret(params["value"]) do
      attrs =
        %{provider: provider, key: key, value: value}
        |> Map.merge(note(params))

      case Credentials.put(attrs, opts(conn)) do
        {:ok, credential} -> json(conn, summarize(credential))
        {:error, error} -> fail(conn, error)
      end
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  def patch(conn, %{"provider" => provider, "key" => key} = params) do
    opts = opts(conn)

    with {:ok, provider} <- slug(provider, "provider"),
         {:ok, key} <- slug(key, "key"),
         {:ok, description} <- description(params["description"]),
         {:ok, %Credential{} = credential} <- Credential.get_slot(provider, key, opts),
         {:ok, updated} <- Credential.update_note(credential, %{description: description}, opts) do
      json(conn, summarize(updated))
    else
      {:ok, nil} -> not_found(conn)
      {:error, message} when is_binary(message) -> bad_request(conn, message)
      {:error, error} -> fail(conn, error)
    end
  end

  def delete(conn, %{"provider" => provider, "key" => key}) do
    opts = opts(conn)

    with {:ok, provider} <- slug(provider, "provider"),
         {:ok, key} <- slug(key, "key"),
         {:ok, %Credential{} = credential} <- Credential.get_slot(provider, key, opts),
         :ok <- Credential.destroy(credential, opts) do
      send_resp(conn, :no_content, "")
    else
      {:ok, nil} -> not_found(conn)
      {:error, message} when is_binary(message) -> bad_request(conn, message)
      {:error, error} -> fail(conn, error)
    end
  end

  defp opts(conn), do: Tenancy.opts(conn.assigns.current_user)

  defp summarize(%Credential{} = c) do
    %{
      tenant: c.tenant_slug,
      provider: c.provider,
      key: c.key,
      description: c.description,
      hint: c.hint,
      value_bytes: c.value_bytes,
      rotated_at: c.rotated_at,
      updated_at: c.updated_at
    }
  end

  defp slug(value, field) do
    if Slots.slug?(value) do
      {:ok, value}
    else
      {:error, "#{field} must be lowercase letters, digits, dashes or underscores"}
    end
  end

  defp secret(value) when is_binary(value) and value != "", do: {:ok, value}
  defp secret(_), do: {:error, "value is required"}

  # A note is only written when the caller sends one, so rotating a secret does
  # not silently wipe the note beside it.
  defp note(params) do
    case Map.fetch(params, "description") do
      {:ok, description} when is_binary(description) -> %{description: description}
      _ -> %{}
    end
  end

  defp description(value) when is_binary(value), do: {:ok, value}
  defp description(_), do: {:error, "description is required"}

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "no such credential"})
  end

  defp bad_request(conn, message) do
    conn |> put_status(:bad_request) |> json(%{error: message})
  end

  # Never `Exception.message/1`: Ash's own messages end in `inspect(value)`, and
  # here the value is the secret. `Errors.describe/1` renders the field and the
  # message template only.
  defp fail(conn, %Ash.Error.Forbidden{} = error) do
    conn |> put_status(:forbidden) |> json(%{error: Errors.describe(error)})
  end

  defp fail(conn, error) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: Errors.describe(error)})
  end
end
