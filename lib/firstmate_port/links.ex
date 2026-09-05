defmodule FirstmatePort.Links do
  @moduledoc """
  HTTPS URL checks. Stored URLs are kept as given; never assembled from parts.
  """

  @doc """
  Accepts a full `https://` URL and returns the trimmed original string.
  """
  @spec https(String.t() | nil) :: {:ok, String.t()} | {:error, :not_https | :empty}
  def https(nil), do: {:error, :empty}
  def https(""), do: {:error, :empty}

  def https(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:error, :empty}

      not String.starts_with?(trimmed, "https://") ->
        {:error, :not_https}

      true ->
        case URI.parse(trimmed) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
            if uri_userinfo?(trimmed) do
              {:error, :not_https}
            else
              {:ok, trimmed}
            end

          _ ->
            {:error, :not_https}
        end
    end
  end

  @doc """
  PRs and issues require a full https URL. Other kinds may omit it.
  """
  @spec progress_url(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_https | :empty | :unknown_kind}
  def progress_url(kind, raw) when kind in ["pr", "issue"] do
    https(raw)
  end

  def progress_url(kind, raw) when kind in ["achievement", "note"] do
    case raw do
      nil -> {:ok, ""}
      "" -> {:ok, ""}
      other -> https(other)
    end
  end

  def progress_url(_kind, _raw), do: {:error, :unknown_kind}

  @spec allowed_email?(String.t(), String.t()) :: boolean()
  def allowed_email?(email, domain) when is_binary(email) and is_binary(domain) do
    case String.split(String.downcase(email), "@", parts: 2) do
      [local, ^domain] when local != "" -> true
      _ -> false
    end
  end

  def allowed_email?(_, _), do: false

  defp uri_userinfo?(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" -> true
      _ -> false
    end
  end
end
