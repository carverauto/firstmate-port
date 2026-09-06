defmodule FirstmatePort.Credentials.DecryptGuard do
  @moduledoc """
  The `AshCloak` `on_decrypt` hook for tenant credentials.

  Decryption has to be asked for by name: a query only gets plaintext back if it
  carries the `:decrypt_credential` context that `FirstmatePort.Credentials` sets.
  Anything else - a LiveView that adds `load: [:value]`, a future action that
  loads it by accident - gets an error instead of a secret.

  It is not a defence against code that means harm, which already runs inside the
  app. It is what makes an accidental exposure fail loudly, and it is where the
  audit line for every decryption is written.
  """

  require Logger

  @context_key :decrypt_credential

  @doc "The context a query must carry to decrypt a credential."
  def context, do: %{@context_key => true}

  @doc "`AshCloak` `on_decrypt` callback."
  def approve(_resource, records, field, context) do
    asked? =
      context
      |> Map.get(:source_context)
      |> Kernel.||(%{})
      |> Map.get(@context_key, false)

    if asked? do
      log(records, field)
      :ok
    else
      {:error, FirstmatePort.Credentials.Errors.DecryptNotRequested.exception(field: field)}
    end
  end

  defp log([], _field), do: :ok

  defp log(records, field) do
    slots =
      records
      |> Enum.map(fn record ->
        "#{record.tenant_slug}:#{record.provider}/#{record.key}"
      end)
      |> Enum.sort()
      |> Enum.join(" ")

    Logger.info("credential decrypt field=#{field} slots=#{slots}")
  end
end
