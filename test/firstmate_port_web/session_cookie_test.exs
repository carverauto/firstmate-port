defmodule FirstmatePortWeb.SessionCookieTest do
  use FirstmatePortWeb.ConnCase, async: false

  import FirstmatePort.Test.AppConfig

  alias FirstmatePort.Accounts.{Password, User}

  test "the hardened cookie preserves sign-in and rejects tampering" do
    put_env(:local_auth, true)
    email = "cookie-#{System.unique_integer([:positive])}@localhost"

    {:ok, _} =
      User.bootstrap_admin(
        %{email: email, name: "Cookie test", hashed_password: Password.hash("known-password")},
        authorize?: false
      )

    signed_in = post(build_conn(), ~p"/auth/local", %{email: email, password: "known-password"})
    assert redirected_to(signed_in) == "/"
    token = get_session(signed_in, :guardian_token)
    assert is_binary(token)
    [header] = get_resp_header(signed_in, "set-cookie")
    assert header =~ "HttpOnly"
    assert header =~ "SameSite=Lax"
    assert header =~ "max-age=43200"
    refute header =~ token

    cookie = signed_in.resp_cookies["_firstmate_port_key"].value
    opts = Plug.Session.COOKIE.init(Application.fetch_env!(:firstmate_port, :session))

    assert {:term, %{"guardian_token" => ^token}} =
             Plug.Session.COOKIE.get(signed_in, cookie, opts)

    sign_only = Map.put(opts, :encryption_salt, nil)
    assert {nil, %{}} = Plug.Session.COOKIE.get(signed_in, cookie, sign_only)

    assert build_conn()
           |> put_req_cookie("_firstmate_port_key", cookie)
           |> get(~p"/")
           |> html_response(200)

    <<first, rest::binary>> = cookie
    altered = <<Bitwise.bxor(first, 1)>> <> rest
    rejected = build_conn() |> put_req_cookie("_firstmate_port_key", altered) |> get(~p"/")
    assert redirected_to(rejected) == "/login"
  end
end
