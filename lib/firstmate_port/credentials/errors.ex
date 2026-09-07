defmodule FirstmatePort.Credentials.Errors do
  @moduledoc """
  Turns an Ash error into a sentence that is safe to hand back to a browser or
  an API client.

  This exists because Ash's own error messages embed the rejected value -
  `Ash.Error.Changes.InvalidArgument.message/1` ends in `inspect(error.value)` -
  and for credentials that value is the secret. So nothing here ever touches
  `:value`: only the field name and the message template, with the template's
  own variables filled in and the result length-capped.

  Written for credentials and safe for anything: a caller whose rejected values
  are not secret loses nothing by scrubbing them anyway, so other resources use
  it too, passing their own `fallback` for the case where Ash gives no message
  at all.
  """

  @max_length 300

  @default_fallback "the credential could not be saved"

  @doc """
  A short, secret-free description of why a write failed.

  `fallback` is what to say when Ash reported nothing quotable, which is the one
  sentence that has to name the caller's own subject rather than a credential.
  """
  def describe(error, fallback \\ @default_fallback)

  def describe(%Ash.Error.Forbidden{}, _fallback) do
    "forbidden: credential writes need a human account in this tenant"
  end

  def describe(message, _fallback) when is_binary(message), do: truncate(message)

  def describe(error, fallback) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map(&sentence/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> fallback
      sentences -> sentences |> Enum.join("; ") |> truncate()
    end
  end

  defp sentence(%Ash.Error.Forbidden.Policy{}), do: "forbidden"
  defp sentence(%{__struct__: struct}) when struct == Ash.Error.Query.NotFound, do: "not found"

  defp sentence(%Ash.Error.Changes.Required{field: field}) do
    "#{field} is required"
  end

  defp sentence(%Ash.Error.Invalid.NoSuchInput{input: input}) do
    "#{input} is not accepted here"
  end

  defp sentence(%{field: field, message: message} = error) when is_binary(message) do
    label(field) <> fill(message, vars(error))
  end

  defp sentence(%{message: message}) when is_binary(message), do: message
  defp sentence(%{class: :forbidden}), do: "forbidden"
  defp sentence(_), do: nil

  defp label(nil), do: ""
  defp label(field), do: "#{field}: "

  # Ash messages carry `%{name}` placeholders filled from the error's vars. The
  # rejected value is never one of them here: `:value` is dropped outright, so a
  # message that referenced it would keep the literal placeholder rather than
  # print a secret.
  defp fill(message, vars) do
    Enum.reduce(vars, message, fn
      {:value, _}, acc -> acc
      {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp vars(error) do
    error
    |> Map.get(:vars, [])
    |> List.wrap()
    |> Enum.filter(fn
      {key, _} when is_atom(key) -> true
      _ -> false
    end)
  end

  defp truncate(message) do
    message = String.trim(message)

    if String.length(message) > @max_length do
      String.slice(message, 0, @max_length) <> "..."
    else
      message
    end
  end
end
