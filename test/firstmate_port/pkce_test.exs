defmodule FirstmatePort.PkceTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Pkce

  test "S256 challenge is base64url without padding" do
    verifier = Pkce.generate_verifier()
    challenge = Pkce.challenge_s256(verifier)
    assert byte_size(verifier) >= 43
    refute String.contains?(challenge, "=")
    assert challenge == Pkce.challenge_s256(verifier)
  end
end
