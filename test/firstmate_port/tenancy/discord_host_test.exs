defmodule FirstmatePort.Tenancy.DiscordHostTest do
  use ExUnit.Case, async: false

  alias FirstmatePort.Tenancy.DiscordHost

  setup do
    previous = Application.get_env(:firstmate_port, :discord_host_suffix)
    on_exit(fn -> Application.put_env(:firstmate_port, :discord_host_suffix, previous) end)
    :ok
  end

  defp with_suffix(suffix), do: Application.put_env(:firstmate_port, :discord_host_suffix, suffix)

  describe "single-tenant (no suffix configured)" do
    setup do
      with_suffix(nil)
      :ok
    end

    test "every host is the default tenant" do
      assert {:ok, "local"} = DiscordHost.tenant("localhost")
      assert {:ok, "local"} = DiscordHost.tenant("discord-firstmate.example.com")
      assert {:ok, "local"} = DiscordHost.tenant("anything.at.all")
    end

    test "no host is a Discord host, so the guard stays inert" do
      refute DiscordHost.interactions_host?("localhost")
      refute DiscordHost.interactions_host?("discord-firstmate.example.com")
    end

    test "there is no per-tenant hostname to advertise" do
      assert DiscordHost.hostname("local") == nil
    end
  end

  describe "multi-tenant (suffix configured)" do
    setup do
      with_suffix(".example.com")
      :ok
    end

    test "the OSS label is the default tenant" do
      assert {:ok, "local"} = DiscordHost.tenant("discord-firstmate.example.com")
    end

    test "any other label is that tenant" do
      assert {:ok, "acme"} = DiscordHost.tenant("discord-acme.example.com")
      assert {:ok, "big-co-2"} = DiscordHost.tenant("discord-big-co-2.example.com")
    end

    test "a port on the Host header is ignored" do
      assert {:ok, "acme"} = DiscordHost.tenant("discord-acme.example.com:443")
    end

    test "case and a trailing root dot are normalized" do
      assert {:ok, "acme"} = DiscordHost.tenant("Discord-ACME.Example.COM")
      assert {:ok, "acme"} = DiscordHost.tenant("discord-acme.example.com.")
    end

    test "a host outside the suffix resolves to no tenant" do
      assert :error = DiscordHost.tenant("discord-acme.evil.test")
      assert :error = DiscordHost.tenant("discord-acme.example.com.evil.test")
    end

    test "a host without the discord- prefix resolves to no tenant" do
      assert :error = DiscordHost.tenant("firstmate.example.com")
      assert :error = DiscordHost.tenant("example.com")
      assert :error = DiscordHost.tenant("acme.example.com")
    end

    test "it never falls back to the default tenant" do
      # The whole point of the seam: a request on the wrong hostname must not be
      # checked against, or published for, the OSS tenant.
      assert :error = DiscordHost.tenant("localhost")
      assert :error = DiscordHost.tenant("")
      assert :error = DiscordHost.tenant(nil)
    end

    test "a deeper label is not a tenant" do
      assert :error = DiscordHost.tenant("discord-acme.staging.example.com")
    end

    test "an empty label is not a tenant" do
      assert :error = DiscordHost.tenant("discord-.example.com")
    end

    test "a label that is not a valid tenant slug resolves to no tenant" do
      assert :error = DiscordHost.tenant("discord-Not_A_Slug.example.com")
      assert :error = DiscordHost.tenant("discord-9lives.example.com")
    end

    test "a suffix written without the leading dot still anchors on one" do
      with_suffix("example.com")

      assert {:ok, "acme"} = DiscordHost.tenant("discord-acme.example.com")
      assert :error = DiscordHost.tenant("discord-acmeexample.com")
    end

    test "Discord hosts are recognized for the guard, including unusable labels" do
      assert DiscordHost.interactions_host?("discord-acme.example.com")
      assert DiscordHost.interactions_host?("discord-firstmate.example.com")
      # Addressed to our Discord hostnames but no tenant will verify it: still
      # confined to /interactions rather than allowed onto the portal.
      assert DiscordHost.interactions_host?("discord-Not_A_Slug.example.com")

      refute DiscordHost.interactions_host?("firstmate.example.com")
      refute DiscordHost.interactions_host?("discord-acme.evil.test")
    end

    test "each tenant's hostname round-trips back to that tenant" do
      for slug <- ["local", "acme", "big-co-2"] do
        hostname = DiscordHost.hostname(slug)
        assert {:ok, ^slug} = DiscordHost.tenant(hostname)
      end

      assert DiscordHost.hostname("local") == "discord-firstmate.example.com"
      assert DiscordHost.hostname("acme") == "discord-acme.example.com"
    end
  end
end
