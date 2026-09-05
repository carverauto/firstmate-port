defmodule FirstmatePortWeb.AuthController do
  @moduledoc """
  Sign-in endpoints.

  The identity-provider routes stay mounted whether or not a provider is
  configured, so that a portal running on local auth answers them with a
  redirect instead of a crash.
  """

  use FirstmatePortWeb, :controller

  # Runs before Ueberauth. Without a loaded provider the strategy fails inside
  # the plug, and these actions answer with a 502 that inspects the underlying
  # error at the visitor. "OIDC is off" is a normal state, not a gateway fault.
  plug :require_oidc when action in [:request, :callback]
  plug Ueberauth when action in [:request, :callback]

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian
  alias FirstmatePort.Auth.OIDC
  alias FirstmatePort.Links

  def request(conn, _params) do
    case conn.assigns[:ueberauth_failure] do
      nil ->
        conn

      fail ->
        conn
        |> put_status(:bad_gateway)
        |> text("OIDC unavailable: #{inspect(fail)}")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    email = email_from(auth)

    with true <- is_binary(email) and email != "",
         true <- email_allowed?(email),
         {:ok, user} <-
           User.upsert_oidc(%{email: email, name: name_from(auth, email)}, authorize?: false),
         {:ok, token, _claims} <- Guardian.encode_and_sign(user, %{typ: "access"}) do
      return_to = get_session(conn, :return_to) || "/"

      conn
      |> delete_session(:return_to)
      |> put_session(:guardian_token, token)
      |> redirect(to: return_to)
    else
      _ ->
        conn
        |> put_status(:forbidden)
        |> text(forbidden_message())
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fail}} = conn, _params) do
    conn
    |> put_flash(:error, "Your identity provider did not complete the sign-in.")
    |> redirect(to: ~p"/login")
  end

  def callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> text("Missing OIDC code")
  end

  def logout(conn, _params) do
    conn
    |> delete_session(:guardian_token)
    |> redirect(to: "/login")
  end

  @doc """
  Sign in with the local account.

  The account is the gate here, not an email domain: the credential was either
  generated on first boot and printed to the logs, or supplied by the operator.
  """
  def local_login(conn, params) do
    if local_auth?() do
      email = params |> Map.get("email", "") |> to_string() |> String.trim()
      password = params |> Map.get("password", "") |> to_string()

      user = fetch_user(email)

      with true <- User.valid_password?(user, password),
           {:ok, token, _claims} <- Guardian.encode_and_sign(user, %{typ: "access"}) do
        return_to = get_session(conn, :return_to) || "/"

        conn
        |> configure_session(renew: true)
        |> delete_session(:return_to)
        |> put_session(:guardian_token, token)
        |> redirect(to: return_to)
      else
        _ ->
          # One message for a bad email and a bad password alike: which half was
          # wrong is not the visitor's business.
          conn
          |> put_flash(:error, "That email and password did not match an account.")
          |> redirect(to: ~p"/login")
      end
    else
      conn
      |> put_status(:not_found)
      |> text("not found")
    end
  end

  defp fetch_user(""), do: nil

  defp fetch_user(email) do
    case User.get_by_email(email, authorize?: false) do
      {:ok, %User{} = user} -> user
      _ -> nil
    end
  end

  defp local_auth?, do: Application.get_env(:firstmate_port, :local_auth, false)

  defp require_oidc(conn, _opts) do
    if OIDC.enabled?() do
      conn
    else
      conn
      |> put_flash(:error, "Sign-in with an identity provider is not available.")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  defp email_from(%Ueberauth.Auth{} = auth) do
    (auth.info && auth.info.email) ||
      get_in(auth.extra.raw_info, [:claims, "email"]) ||
      get_in(auth.extra.raw_info, [:claims, "preferred_username"])
  end

  defp name_from(%Ueberauth.Auth{} = auth, email) do
    (auth.info && auth.info.name) || email
  end

  # An allowlist is optional. With none set, anyone the identity provider
  # authenticates may sign in -- the provider is the gate. A domain is an extra
  # restriction for sites that want one, never the product's login wall.
  defp email_allowed?(email) do
    case allowed_domain() do
      nil -> true
      domain -> Links.allowed_email?(email, domain)
    end
  end

  defp forbidden_message do
    case allowed_domain() do
      nil -> "Your identity provider did not return a usable email address."
      domain -> "Access restricted to @#{domain} accounts."
    end
  end

  defp allowed_domain do
    case Application.get_env(:firstmate_port, :allowed_email_domain) do
      domain when is_binary(domain) ->
        case String.trim(domain) do
          "" -> nil
          domain -> domain
        end

      _ ->
        nil
    end
  end
end
