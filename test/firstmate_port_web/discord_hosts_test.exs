defmodule FirstmatePortWeb.DiscordHostsTest do
  use ExUnit.Case, async: false

  alias FirstmatePortWeb.DiscordHosts

  setup do
    previous = Application.get_env(:firstmate_port, :discord_interactions_host)

    on_exit(fn ->
      Application.put_env(:firstmate_port, :discord_interactions_host, previous)
    end)

    :ok
  end

  defp configure(value),
    do: Application.put_env(:firstmate_port, :discord_interactions_host, value)

  describe "nothing published" do
    test "an unset value treats no hostname as public" do
      configure(nil)

      refute DiscordHosts.interactions_host?("localhost")
      refute DiscordHosts.interactions_host?("discord.example.com")
      assert DiscordHosts.host() == nil
      assert DiscordHosts.interactions_url() == nil
    end

    test "an empty string, nil, and junk are all the same as unset" do
      for value <- ["", "   ", nil] do
        configure(value)

        assert DiscordHosts.host() == nil, "#{inspect(value)} published a hostname"
        refute DiscordHosts.interactions_host?("discord.example.com")
      end
    end
  end

  describe "published hostnames" do
    test "a configured hostname names the URL" do
      configure("discord.example.com")

      assert DiscordHosts.host() == "discord.example.com"
      assert DiscordHosts.interactions_host?("discord.example.com")
      assert DiscordHosts.interactions_url() == "https://discord.example.com/interactions"
    end

    test "matching ignores case, port, and the trailing root dot" do
      configure("Discord.Example.COM:443.")

      assert DiscordHosts.host() == "discord.example.com"

      for host <- [
            "discord.example.com",
            "DISCORD.example.com",
            "discord.example.com:443",
            "discord.example.com."
          ] do
        assert DiscordHosts.interactions_host?(host), "#{host} did not match"
      end
    end

    test "a hostname that was not published is not one of ours" do
      configure("discord.example.com")

      for host <- [
            "discord.example.com.evil.test",
            "evil.discord.example.com",
            "discord.example.co",
            "firstmate.example.com",
            "",
            nil
          ] do
        refute DiscordHosts.interactions_host?(host), "#{inspect(host)} matched"
      end
    end
  end
end
