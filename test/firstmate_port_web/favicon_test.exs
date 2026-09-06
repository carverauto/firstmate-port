defmodule FirstmatePortWeb.FaviconTest do
  use FirstmatePortWeb.ConnCase, async: true

  @stub_size 152

  test "favicon.ico is a real multi-size ICO, not the 152-byte stub" do
    path = Application.app_dir(:firstmate_port, "priv/static/favicon.ico")
    assert File.exists?(path)
    {:ok, <<0, 0, 1, 0, count::little-16, _rest::binary>> = bin} = File.read(path)
    assert count >= 2, "expected a multi-size ICO, got #{count} image(s)"
    assert byte_size(bin) != @stub_size, "favicon.ico is still the empty stub"
    assert byte_size(bin) > 1_000
  end

  test "apple-touch-icon.png exists and is a PNG" do
    path = Application.app_dir(:firstmate_port, "priv/static/apple-touch-icon.png")
    assert File.exists?(path)
    {:ok, <<0x89, 0x50, 0x4E, 0x47, _rest::binary>> = bin} = File.read(path)
    assert byte_size(bin) > 1_000
  end

  test "GET /favicon.ico serves the ICO" do
    conn = get(build_conn(), ~p"/favicon.ico")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "icon"
  end

  test "login page links the theme-aware SVG icons plus ico fallback" do
    body = build_conn() |> get(~p"/login") |> html_response(200)
    assert body =~ ~s|media="(prefers-color-scheme: light)"|
    assert body =~ "/images/steering-wheel-black.svg"
    assert body =~ "/images/steering-wheel-white.svg"
    assert body =~ ~s|rel="icon" href="/favicon.ico"|
    assert body =~ ~s|rel="apple-touch-icon" href="/apple-touch-icon.png"|
  end

  test "signed-in portal links icons that the endpoint serves" do
    alias FirstmatePort.Accounts.{Tenant, User}

    {:ok, _} = Tenant.seed(%{slug: "favicon", name: "Favicon"}, authorize?: false)

    {:ok, user} =
      User.upsert_oidc(
        %{email: "favicon@example.com", name: "Favicon", tenant_slug: "favicon"},
        authorize?: false
      )

    {:ok, token, _} = FirstmatePort.Auth.Guardian.encode_and_sign(user, %{})

    body =
      build_conn()
      |> init_test_session(%{guardian_token: token})
      |> get(~p"/")
      |> html_response(200)

    assert body =~ "Fleet log"

    for path <- [
          "/favicon.ico",
          "/images/steering-wheel-black.svg",
          "/images/steering-wheel-white.svg",
          "/apple-touch-icon.png"
        ] do
      assert body =~ ~s|href="#{path}"|
      assert build_conn() |> get(path) |> response(200) != ""
    end
  end
end
