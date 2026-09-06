defmodule FirstmatePortWeb.OIDCAllowlistTest do
  @moduledoc """
  The identity provider is the gate for OIDC sign-in. A domain allowlist is an
  extra restriction a site may opt into, never the product's login wall.
  """
  use FirstmatePortWeb.ConnCase

  alias FirstmatePort.Links

  setup do
    original = Application.get_env(:firstmate_port, :allowed_email_domain)
    on_exit(fn -> Application.put_env(:firstmate_port, :allowed_email_domain, original) end)
    :ok
  end

  test "no allowlist is configured by default" do
    # The reported failure was a live portal answering the OIDC callback with
    # "Access restricted to @<domain> accounts."
    assert Application.get_env(:firstmate_port, :allowed_email_domain) in [nil, ""]
  end

  test "the allowlist helper still gates when a site opts in" do
    assert Links.allowed_email?("captain@example.com", "example.com")
    refute Links.allowed_email?("captain@elsewhere.com", "example.com")
  end
end
