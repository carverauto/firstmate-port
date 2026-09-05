defmodule FirstmatePortWeb.AuthController do
  use FirstmatePortWeb, :controller

  plug Ueberauth when action in [:request, :callback]

  alias FirstmatePort.Accounts.User
  alias FirstmatePort.Auth.Guardian
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
         true <- Links.allowed_email?(email, allowed_domain()),
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
        |> text("Access restricted to @#{allowed_domain()} accounts.")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fail}} = conn, _params) do
    conn
    |> put_status(:forbidden)
    |> text("Access restricted to @#{allowed_domain()} accounts.")
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

  def dev_login(conn, %{"email" => email}) do
    if Application.get_env(:firstmate_port, :dev_auth, false) do
      email = String.trim(email || "")

      with true <- email != "",
           true <- Links.allowed_email?(email, allowed_domain()) or local_dev_email?(email),
           {:ok, user} <- User.upsert_oidc(%{email: email, name: email}, authorize?: false),
           {:ok, token, _claims} <- Guardian.encode_and_sign(user, %{typ: "access"}) do
        return_to = get_session(conn, :return_to) || "/"

        conn
        |> delete_session(:return_to)
        |> put_session(:guardian_token, token)
        |> redirect(to: return_to)
      else
        _ ->
          conn
          |> put_flash(:error, "That email is not on the local allowlist.")
          |> redirect(to: "/login")
      end
    else
      conn
      |> put_status(:not_found)
      |> text("not found")
    end
  end

  defp local_dev_email?(email) do
    String.ends_with?(email, "@localhost") or String.ends_with?(email, "@example.com")
  end

  defp email_from(%Ueberauth.Auth{} = auth) do
    (auth.info && auth.info.email) ||
      get_in(auth.extra.raw_info, [:claims, "email"]) ||
      get_in(auth.extra.raw_info, [:claims, "preferred_username"])
  end

  defp name_from(%Ueberauth.Auth{} = auth, email) do
    (auth.info && auth.info.name) || email
  end

  defp allowed_domain do
    Application.get_env(:firstmate_port, :allowed_email_domain, "localhost")
  end
end
