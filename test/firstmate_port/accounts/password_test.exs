defmodule FirstmatePort.Accounts.PasswordTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias FirstmatePort.Accounts.Password

  test "a hash verifies against its own password and nothing else" do
    hash = Password.hash("hunter2")

    assert Password.verify("hunter2", hash)
    refute Password.verify("hunter3", hash)
    refute Password.verify("", hash)
  end

  test "the same password hashes differently every time" do
    # A per-hash salt, so two accounts sharing a password are not visibly equal
    # and a stored hash cannot be looked up in a rainbow table.
    refute Password.hash("hunter2") == Password.hash("hunter2")
  end

  test "the work factor travels with the hash" do
    assert "pbkdf2-sha512$" <> rest = Password.hash("hunter2")
    assert [iterations, salt, hash] = String.split(rest, "$")
    assert {n, ""} = Integer.parse(iterations)
    assert n > 0
    assert {:ok, _} = Base.url_decode64(salt, padding: false)
    assert {:ok, _} = Base.url_decode64(hash, padding: false)
  end

  test "an account with no password cannot be signed into" do
    refute Password.verify("anything", nil)
    refute Password.verify("anything", "")
    refute Password.verify("anything", "not-a-hash")
  end

  test "a missing password is refused rather than accepted" do
    refute Password.verify(nil, Password.hash("hunter2"))
  end

  test "generated passwords are long and unique" do
    passwords = Enum.map(1..25, fn _ -> Password.generate() end)

    assert Enum.uniq(passwords) == passwords
    assert Enum.all?(passwords, &(String.length(&1) >= 24))
  end
end
