defmodule FirstmatePort.Accounts.Bootstrap do
  @moduledoc """
  First-run credentials: the agent service token, and the local admin account
  that makes a fresh portal signable-into without any identity provider.
  """

  alias FirstmatePort.Accounts.Password
  alias FirstmatePort.Accounts.User

  require Logger

  @default_email "admin@localhost"

  def ensure_agent! do
    case System.get_env("FIRSTMATE_AGENT_TOKEN") do
      token when is_binary(token) and token != "" ->
        {:ok, _} =
          User.bootstrap_agent(
            %{
              email: "agent@localhost",
              name: "firstmate agent",
              hashed_api_key: User.hash_token(token)
            },
            authorize?: false
          )

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Make sure someone can sign in.

  The password comes from `BOOTSTRAP_ADMIN_PASSWORD` when set — in Kubernetes
  that is a secret the operator can read back with `kubectl get`. Otherwise one
  is generated and printed once, which is how it reaches you from
  `docker compose logs`.

  Runs on every boot but only writes on the first, so restarting the portal
  never rotates a password out from under whoever is holding it. Nothing here
  raises: a portal that cannot write a bootstrap account should still come up
  and say so.
  """
  @spec ensure_admin!() :: :ok
  def ensure_admin! do
    if local_auth?() do
      email = configured_email()

      case existing_admin(email) do
        {:ok, %User{hashed_password: hash}} when is_binary(hash) ->
          :ok

        _ ->
          create_admin(email, System.get_env("BOOTSTRAP_ADMIN_PASSWORD"))
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.error("Could not create the local admin account: #{Exception.message(error)}")
      :ok
  end

  defp create_admin(email, password) when is_binary(password) and password != "" do
    with :ok <- write_admin(email, password) do
      Logger.info("Local sign-in ready for #{email} using BOOTSTRAP_ADMIN_PASSWORD.")
    end
  end

  defp create_admin(email, _password) do
    password = Password.generate()

    with :ok <- write_admin(email, password) do
      # The only time this password is ever visible. It is not recoverable from
      # the database, and it is not printed again on later boots.
      Logger.info(
        "\n" <>
          box([
            "first-run sign-in",
            "",
            "  email:    " <> email,
            "  password: " <> password,
            "",
            "Shown once. Set BOOTSTRAP_ADMIN_PASSWORD to choose your own."
          ])
      )
    end
  end

  @box_width 66

  defp box(lines) do
    rule = String.duplicate("─", @box_width)

    body =
      Enum.map(lines, fn line ->
        "│ " <> String.pad_trailing(line, @box_width - 2) <> " │"
      end)

    Enum.join(["┌" <> rule <> "┐"] ++ body ++ ["└" <> rule <> "┘"], "\n")
  end

  defp write_admin(email, password) do
    case User.bootstrap_admin(
           %{email: email, name: "firstmate admin", hashed_password: Password.hash(password)},
           authorize?: false
         ) do
      {:ok, _user} ->
        :ok

      {:error, error} ->
        Logger.error("Could not create the local admin account: #{inspect(error)}")
        :error
    end
  end

  defp existing_admin(email) do
    User.get_by_email(email, authorize?: false)
  end

  defp configured_email do
    case System.get_env("BOOTSTRAP_ADMIN_EMAIL") do
      email when is_binary(email) and email != "" -> String.trim(email)
      _ -> @default_email
    end
  end

  defp local_auth?, do: Application.get_env(:firstmate_port, :local_auth, false)
end
