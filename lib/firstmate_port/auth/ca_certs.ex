defmodule FirstmatePort.Auth.CACerts do
  @moduledoc """
  Resolve a CA trust store once, before anything opens an outbound TLS socket.

  OTP finds the operating system trust store by trying a fixed list of paths
  (`pubkey_os_cacerts:linux_paths/0`), and `httpc` reaches for it lazily the
  first time an HTTPS request omits `:ssl` options. On a slim image with no CA
  bundle that lookup fails with `:no_cacerts_found`, and `public_key` has no
  `conv_error_reason/1` clause for that atom (still true in 1.20), so it raises
  `FunctionClauseError` instead of returning an error. Callers that reasonably
  expect an error tuple die instead.

  Pointing `:public_key` at a bundle we ship makes the common case work and
  keeps the uncommon case legible. It is hygiene, not a safety net: callers must
  still survive a node with no usable trust store.
  """

  require Logger

  # SSL_CERT_FILE is the OpenSSL convention; OTP does not read it. Honouring it
  # here is what makes it mean anything to this node.
  @env_vars ~w(OIDC_CACERTFILE SSL_CERT_FILE)
  @bundled "priv/ssl/cacert.pem"

  @type source :: :os | {:file, Path.t()}

  @doc """
  Pick a trust store and, when it is a file, tell `:public_key` to use it.

  Never raises. Returns `{:error, :no_trust_store}` when nothing is available,
  leaving outbound TLS broken but the node running.
  """
  @spec configure() :: {:ok, source()} | {:error, :no_trust_store}
  def configure do
    case resolve() do
      {:ok, :os} ->
        # Worth a line: when TLS breaks in a container, the first question is
        # always which trust store the node actually picked up.
        Logger.info("TLS trust store: operating system bundle")
        {:ok, :os}

      {:ok, {:file, path}} ->
        # Read lazily by pubkey_os_cacerts on first use, so setting it after
        # boot is fine as long as nothing has loaded a store yet.
        Application.put_env(:public_key, :cacerts_path, path)
        Logger.info("TLS trust store: #{path}")
        {:ok, {:file, path}}

      :error ->
        Logger.warning(
          "No CA trust store found (looked at #{Enum.join(@env_vars, ", ")}, the OS bundle, " <>
            "and #{@bundled}). Outbound TLS will fail until one is installed."
        )

        {:error, :no_trust_store}
    end
  end

  @doc "Whether a usable trust store is reachable right now."
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _}, resolve())
  end

  defp resolve do
    cond do
      path = configured_file() -> {:ok, {:file, path}}
      os_trust_store?() -> {:ok, :os}
      path = bundled_file() -> {:ok, {:file, path}}
      true -> :error
    end
  end

  defp configured_file do
    Enum.find_value(@env_vars, fn var ->
      with path when is_binary(path) <- System.get_env(var),
           path = String.trim(path),
           true <- path != "" and File.regular?(path) do
        path
      else
        _ -> nil
      end
    end)
  end

  defp bundled_file do
    path = Path.join(Application.app_dir(:firstmate_port), @bundled)
    if File.regular?(path), do: path
  rescue
    # app_dir/1 raises if the app is not loaded yet.
    _ -> nil
  end

  # public_key raises rather than returning an error when no bundle is present,
  # which is the whole reason this module exists.
  defp os_trust_store? do
    :public_key.cacerts_get() != []
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
