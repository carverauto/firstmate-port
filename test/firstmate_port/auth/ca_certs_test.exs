defmodule FirstmatePort.Auth.CACertsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias FirstmatePort.Auth.CACerts

  setup do
    original = Application.get_env(:public_key, :cacerts_path)
    env = System.get_env("OIDC_CACERTFILE")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:public_key, :cacerts_path)
        path -> Application.put_env(:public_key, :cacerts_path, path)
      end

      case env do
        nil -> System.delete_env("OIDC_CACERTFILE")
        value -> System.put_env("OIDC_CACERTFILE", value)
      end
    end)

    :ok
  end

  test "an explicit bundle wins and is handed to public_key" do
    bundled = Path.join(Application.app_dir(:firstmate_port), "priv/ssl/cacert.pem")
    System.put_env("OIDC_CACERTFILE", bundled)

    assert {:ok, {:file, ^bundled}} = CACerts.configure()
    assert Application.get_env(:public_key, :cacerts_path) == bundled
  end

  test "a path that does not exist is ignored rather than trusted" do
    # Setting :cacerts_path to a missing file would stop public_key looking at
    # the OS bundle at all, turning a typo into a node with no trust store.
    System.put_env("OIDC_CACERTFILE", "/definitely/not/a/ca/bundle.pem")

    assert {:ok, source} = CACerts.configure()
    refute source == {:file, "/definitely/not/a/ca/bundle.pem"}
  end

  test "the app ships a bundle, so an image without an OS store still has one" do
    assert File.regular?(Path.join(Application.app_dir(:firstmate_port), "priv/ssl/cacert.pem"))
    assert CACerts.available?()
  end

  test "resolution never raises, whatever the environment looks like" do
    System.put_env("OIDC_CACERTFILE", "")
    assert CACerts.available?() in [true, false]
  end
end
