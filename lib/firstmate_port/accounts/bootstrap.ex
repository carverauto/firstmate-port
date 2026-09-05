defmodule FirstmatePort.Accounts.Bootstrap do
  @moduledoc "Loads the agent service credential from FIRSTMATE_AGENT_TOKEN."

  alias FirstmatePort.Accounts.User

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
end
