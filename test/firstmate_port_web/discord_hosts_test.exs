defmodule FirstmatePortWeb.DiscordHostsTest do
  use ExUnit.Case, async: false

  alias FirstmatePortWeb.DiscordHosts

  setup do
    previous = Application.get_env(:firstmate_port, :discord_interactions_hosts)

    on_exit(fn ->
      Application.put_env(:firstmate_port, :discord_interactions_hosts, previous)
    end)

    :ok
  end

  defp configure(value),
    do: Application.put_env(:firstmate_port, :discord_interactions_hosts, value)

  describe "nothing published" do
    test "an empty list treats no hostname as public" do
      configure([])

      refute DiscordHosts.interactions_host?("localhost")
      refute DiscordHosts.interactions_host?("discord.example.com")
      assert DiscordHosts.hosts() == []
      assert DiscordHosts.interactions_url() == nil
    end

    test "an empty string, nil, and junk are all the same as unset" do
      for value <- ["", "   ", ",,", nil, 42] do
        configure(value)

        assert DiscordHosts.hosts() == [], "#{inspect(value)} published a hostname"
        refute DiscordHosts.interactions_host?("discord.example.com")
      end
    end
  end

  describe "published hostnames" do
    test "a comma separated string is the runtime form" do
      configure("discord.example.com, discord.example.org")

      assert DiscordHosts.hosts() == ["discord.example.com", "discord.example.org"]
      assert DiscordHosts.interactions_host?("discord.example.com")
      assert DiscordHosts.interactions_host?("discord.example.org")
    end

    test "a list is the config form" do
      configure(["discord.example.com"])

      assert DiscordHosts.hosts() == ["discord.example.com"]
      assert DiscordHosts.interactions_host?("discord.example.com")
    end

    test "matching ignores case, port, and the trailing root dot" do
      configure(["Discord.Example.COM:443."])

      assert DiscordHosts.hosts() == ["discord.example.com"]

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
      configure(["discord.example.com"])

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

    test "duplicates collapse and the first published hostname names the URL" do
      configure(["discord.example.com", "DISCORD.example.com", "discord.example.org"])

      assert DiscordHosts.hosts() == ["discord.example.com", "discord.example.org"]
      assert DiscordHosts.interactions_url() == "https://discord.example.com/interactions"
    end
  end
end
