defmodule FirstmatePortWeb.CredentialsJourneyTest do
  use FirstmatePortWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FirstmatePort.Accounts.{Tenant, User}
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Repo

  @host_suffix ".example.com"

  setup do
    previous = Application.get_env(:firstmate_port, :discord_host_suffix)
    Application.put_env(:firstmate_port, :discord_host_suffix, @host_suffix)
    on_exit(fn -> Application.put_env(:firstmate_port, :discord_host_suffix, previous) end)
    :ok
  end

