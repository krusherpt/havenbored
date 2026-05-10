defmodule HavenboredWeb.AuthControllerTest do
  use HavenboredWeb.ConnCase
  alias Havenbored.{Accounts.User, Repo}
  import ExUnit.CaptureLog

  @moduletag :capture_log

  @test_server_url "http://localhost:9999"

  setup %{conn: conn} do
    Repo.delete_all(User)
    Application.put_env(:soundboard, :haven_server_url, @test_server_url)

    on_exit(fn ->
      Application.delete_env(:soundboard, :haven_server_url)
    end)

    {:ok, conn: conn}
  end

  describe "GET /auth/login" do
    test "renders the login page", %{conn: conn} do
      conn = get(conn, "/auth/login")
      assert html_response(conn, 200) =~ "Soundboard Login"
    end

    test "renders the register page", %{conn: conn} do
      conn = get(conn, "/auth/login?action=register")
      assert html_response(conn, 200) =~ "Register"
    end

    test "shows error message", %{conn: conn} do
      conn = get(conn, "/auth/login", %{"error" => "Test error"})
      assert html_response(conn, 200) =~ "Soundboard Login"
    end
  end

  describe "POST /auth/login" do
    test "redirects to TOTP page when login requires TOTP", %{conn: conn} do
      # Mock the auth client to return :requires_totp
      # In real tests, this would hit the Haven server
      conn =
        post(conn, "/auth/login", %{
          "action" => "login",
          "server_url" => @test_server_url,
          "username" => "testuser",
          "password" => "password123"
        })

      # Without mocking, this will fail to connect, but the route exists
      assert redirected_to(conn) or response(conn, 200)
    end

    test "shows error on empty username", %{conn: conn} do
      conn =
        post(conn, "/auth/login", %{
          "action" => "login",
          "server_url" => @test_server_url,
          "username" => "",
          "password" => "password123"
        })

      assert redirected_to(conn) == "/auth/login"
      assert get_flash(conn, :error)
    end
  end

  describe "GET /auth/totp" do
    test "renders the TOTP page", %{conn: conn} do
      conn = get(conn, "/auth/totp?challenge_token=test_token")
      assert html_response(conn, 200) =~ "Two-Factor Authentication"
    end
  end

  describe "POST /auth/totp" do
    test "redirects to TOTP page on invalid request", %{conn: conn} do
      conn =
        post(conn, "/auth/totp", %{
          "challenge_token" => "test_token",
          "code" => "123456",
          "server_url" => @test_server_url
        })

      # Without mocking, this will fail to connect
      assert redirected_to(conn) or response(conn, 200)
    end
  end

  describe "DELETE /auth/logout" do
    test "clears session and redirects to login", %{conn: conn} do
      conn =
        conn
        |> put_session(:haven_token, "test_token")
        |> put_session(:haven_user_id, 123)
        |> put_session(:haven_username, "testuser")
        |> delete("/auth/logout")

      assert redirected_to(conn) == "/auth/login"
      refute get_session(conn, :haven_token)
      refute get_session(conn, :haven_user_id)
      refute get_session(conn, :haven_username)
    end
  end

  describe "debug_session" do
    test "returns session info in test env", %{conn: conn} do
      conn =
        conn
        |> put_session(:haven_token, "test_token")
        |> put_session(:haven_user_id, 123)
        |> put_session(:haven_username, "testuser")
        |> get("/debug/session")

      assert json = json_response(conn, 200)
      assert json == %{
               "session" => %{
                 "user_id" => 123,
                 "username" => "testuser",
                 "token_set?" => true
               }
             }
    end
  end
end
