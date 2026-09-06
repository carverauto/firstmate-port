defmodule FirstmatePort.Credentials.Slots do
  @moduledoc """
  The catalogue of credential slots a tenant can fill from the portal.

  A slot is a `provider`/`key` pair, both lowercase slugs. Well-known slots are
  listed here so the UI can describe them and so obviously malformed values are
  rejected before they reach the store. Anything not listed is still accepted as
  a generic slot, which is how a new integration gets credentials without a
  schema change.
  """

  @slug ~r/^[a-z][a-z0-9_-]{0,62}$/

  @catalog [
    %{
      provider: "discord",
      key: "public_key",
      label: "Discord interactions public key",
      format: :hex64,
      about:
        "Ed25519 public key from the Discord developer portal. Every interaction for this tenant's Discord application is verified with it before anything is published."
    },
    %{
      provider: "discord",
      key: "bot_token",
      label: "Discord bot token",
      format: :opaque,
      about: "Used for outbound Discord calls. Never sent to the browser once stored."
    },
    %{
      provider: "github",
      key: "token",
      label: "GitHub token",
      format: :opaque,
      about:
        "Personal access token used to poll issues, PRs, and their checks. A fine-grained token needs Checks: Read alongside read access to the repositories you want on the Fleet log; a classic token needs `repo`. Stored here, it takes precedence over the GITHUB_TOKEN environment variable."
    },
    %{
      provider: "github",
      key: "org",
      label: "GitHub organisation",
      format: :slug,
      about:
        "The organisation the poll searches for open PRs and issues, e.g. `carverauto`. Takes precedence over the GITHUB_ORG environment variable."
    },
    %{
      provider: "github",
      key: "webhook_secret",
      label: "GitHub webhook secret",
      format: :opaque,
      about: "Shared secret for verifying inbound GitHub webhooks."
    },
    %{
      provider: "embeddings",
      key: "api_key",
      label: "Fleet-log embedding API key",
      format: :opaque,
      about:
        "Key for the embedding provider named in this tenant's model, e.g. openai, google, or mistral. Optional: without it, fleet search runs on Postgres text search alone. With it, the indexed text of the fleet log is sent to that provider."
    },
    %{
      provider: "oidc",
      key: "client_secret",
      label: "OIDC client secret",
      format: :opaque,
      about: "Client secret for this tenant's identity provider."
    },
    %{
      provider: "webhook",
      key: "signing_secret",
      label: "Outbound webhook signing secret",
      format: :opaque,
      about: "Secret this tenant's webhook receivers use to verify our signatures."
    }
  ]

  @doc "Every well-known slot, in the order the portal lists them."
  def catalog, do: @catalog

  @doc "The well-known slot for a provider/key pair, or `:error`."
  def fetch(provider, key) do
    case Enum.find(@catalog, &(&1.provider == provider and &1.key == key)) do
      nil -> :error
      slot -> {:ok, slot}
    end
  end

  @doc "The distinct providers in the catalogue."
  def providers, do: @catalog |> Enum.map(& &1.provider) |> Enum.uniq()

  @doc "Whether a provider or key is a usable slug."
  def slug?(value) when is_binary(value), do: Regex.match?(@slug, value)
  def slug?(_), do: false

  @doc """
  Checks a secret against the slot's expected shape.

  Returns `:ok` or `{:error, message}`. Unknown slots only have to be non-empty
  and within the length the column accepts.
  """
  def validate_value(provider, key, value) when is_binary(value) do
    case fetch(provider, key) do
      {:ok, %{format: format}} -> validate_format(format, value)
      :error -> validate_format(:opaque, value)
    end
  end

  def validate_value(_provider, _key, _value), do: {:error, "must be a string"}

  defp validate_format(:hex64, value) do
    if Regex.match?(~r/^[0-9a-fA-F]{64}$/, value) do
      :ok
    else
      {:error, "must be 64 hex characters"}
    end
  end

  defp validate_format(:slug, value) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,98}$/, value) do
      :ok
    else
      {:error, "must be a GitHub name"}
    end
  end

  defp validate_format(:opaque, ""), do: {:error, "must not be blank"}

  defp validate_format(:opaque, value) do
    cond do
      byte_size(value) > 8192 -> {:error, "must be at most 8192 bytes"}
      String.match?(value, ~r/[\r\n]/) -> {:error, "must not contain line breaks"}
      true -> :ok
    end
  end

  @doc """
  The hint shown in place of a stored secret. Short values show nothing at all
  rather than most of themselves.
  """
  def hint(value) when is_binary(value) do
    if String.length(value) >= 12, do: String.slice(value, -4, 4), else: ""
  end

  def hint(_), do: ""
end
