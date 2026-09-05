defmodule FirstmatePort.Accounts.Password do
  @moduledoc """
  Password hashing for the local sign-in account.

  PBKDF2-HMAC-SHA512 from OTP's `:crypto`, so local sign-in needs no additional
  dependency. The controller verifies the password before issuing a Guardian
  session; Guardian does not consume the password hash.

  Stored as `pbkdf2-sha512$<iterations>$<salt>$<hash>`, so the work factor
  travels with the hash and can be raised later without invalidating anyone.
  """

  # OWASP's floor for PBKDF2-HMAC-SHA512. Lowered in test config, where the only
  # thing this cost buys is a slower suite.
  @default_iterations 210_000
  @salt_bytes 16
  @hash_bytes 64
  @digest :sha512
  @prefix "pbkdf2-sha512"

  @doc "Hash a password for storage."
  @spec hash(String.t()) :: String.t()
  def hash(password) when is_binary(password) do
    iterations = iterations()
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    derived = derive(password, salt, iterations)

    Enum.join([@prefix, iterations, encode(salt), encode(derived)], "$")
  end

  @doc """
  Check a password against a stored hash.

  Always does the same work for a missing user, a user with no password, and a
  wrong password, so that a caller cannot tell them apart by timing.
  """
  @spec verify(String.t() | nil, String.t() | nil) :: boolean()
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    case String.split(stored, "$") do
      [@prefix, iterations, salt, hash] ->
        with {iterations, ""} when iterations > 0 <- Integer.parse(iterations),
             {:ok, salt} <- decode(salt),
             {:ok, hash} <- decode(hash) do
          secure_compare(derive(password, salt, iterations), hash)
        else
          _ -> decoy(password)
        end

      _ ->
        decoy(password)
    end
  end

  def verify(password, _stored) when is_binary(password), do: decoy(password)
  def verify(_password, _stored), do: false

  @doc "A password worth printing once and pasting into a password manager."
  @spec generate() :: String.t()
  def generate do
    24 |> :crypto.strong_rand_bytes() |> encode()
  end

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(@digest, password, salt, iterations, @hash_bytes)
  end

  # Burn comparable time on inputs that cannot match, so "no such user" and
  # "wrong password" are indistinguishable from the outside.
  defp decoy(password) do
    _ = derive(password, :crypto.strong_rand_bytes(@salt_bytes), iterations())
    false
  end

  defp secure_compare(left, right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp iterations do
    Application.get_env(:firstmate_port, __MODULE__, [])
    |> Keyword.get(:iterations, @default_iterations)
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
  defp decode(string), do: Base.url_decode64(string, padding: false)
end
