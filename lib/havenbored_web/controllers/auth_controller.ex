defmodule HavenboredWeb.AuthController do
  use HavenboredWeb, :controller

  alias Havenbored.Haven.AuthClient

  @doc """
  Show the login page.
  """
  def login(conn, params) do
    action = Map.get(params, "action", "login")
    render(conn, :login, action: action, error: nil, server_url: default_server_url())
  end

  @doc """
  Handle login form submission.
  """
  def login_post(conn, %{"action" => "register"} = params) do
    handle_register(conn, params)
  end

  def login_post(conn, params) do
    handle_login(conn, params)
  end

   @doc """
   Show the TOTP validation page.
   """
   def totp(conn, %{"challenge_token" => challenge_token}) do
     render(conn, :totp, challenge_token: challenge_token)
   end
 
  @doc """
  Handle TOTP validation after login returned :requires_totp.
  """
   def totp_post(conn, %{"challenge_token" => challenge_token, "code" => code, "server_url" => server_url} = _params) do
     server_url = server_url || default_server_url()
 
     case AuthClient.validate_totp(server_url, challenge_token, code) do
       {:ok, token: token, user: user_info} ->
         store_session(conn, token, user_info)
 
       {:error, reason} ->
         conn
         |> put_flash(:error, error_message(reason))
         |> redirect(to: "/auth/totp?challenge_token=#{challenge_token}")
     end
   end
 
   def totp_post(conn, _params) do
     conn
     |> put_flash(:error, "Invalid request")
     |> redirect(to: "/auth/login")
   end
  end

  @doc """
  Logout the current user.
  """
  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/auth/login")
  end

  @doc """
  Debug session info (test env only).
  """
  def debug_session(conn, _params) do
    json(conn, %{
      session: %{
        user_id: get_session(conn, :haven_user_id),
        username: get_session(conn, :haven_username),
        token_set?: not is_nil(get_session(conn, :haven_token))
      }
    })
  end

  ## Internal functions

   defp handle_login(conn, %{"username" => username, "password" => password, "server_url" => server_url_param} = _params) do
     username = String.trim(username)
     server_url = server_url_param || conn.assigns[:haven_server_url] || default_server_url()
 
     if username == "" or password == "" do
       render(conn, :login,
         action: "login",
         error: "Username and password are required",
         server_url: server_url
       )
     else
       case AuthClient.login(server_url, username, password) do
         {:ok, token: token, user: user_info} ->
           store_session(conn, token, user_info)
 
         {:requires_totp, challenge_token: challenge_token} ->
           conn
           |> redirect(to: "/auth/totp?challenge_token=#{challenge_token}&server_url=#{URI.encode_www_form(server_url)}")
 
         {:error, reason} ->
           render(conn, :login,
             action: "login",
             error: error_message(reason),
             server_url: server_url
           )
       end
     end
   end
 
   defp handle_login(conn, _params) do
     render(conn, :login,
       action: "login",
       error: "Invalid request",
       server_url: default_server_url()
     )


   defp handle_register(conn, %{"username" => username, "password" => password, "server_url" => server_url_param} = _params) do
     username = String.trim(username)
     server_url = server_url_param || conn.assigns[:haven_server_url] || default_server_url()
 
     if username == "" or password == "" do
       render(conn, :login,
         action: "register",
         error: "Username and password are required",
         server_url: server_url
       )
     else
       registration_token = Map.get(params, "registration_token", "")
       eula_version = "1"
 
       case AuthClient.register(server_url, username, password, eula_version, true, registration_token) do
         {:ok, token: token, user: user_info} ->
           store_session(conn, token, user_info)
 
         {:error, reason} ->
           render(conn, :login,
             action: "register",
             error: error_message(reason),
             server_url: server_url
           )
       end
     end
   end

  defp handle_register(conn, _params) do
    render(conn, :login,
      action: "register",
      error: "Invalid request",
      server_url: default_server_url()
    )
  end

  defp store_session(conn, token, user_info) do
    conn
    |> put_session(:haven_token, token)
    |> put_session(:haven_user_id, user_info.id)
    |> put_session(:haven_username, user_info.username)
    |> redirect(to: "/")
  end

  defp error_message({:http_error, 401, _}) do
    "Invalid username or password"
  end

  defp error_message({:http_error, 403, msg}) do
    msg
  end

  defp error_message({:http_error, 400, msg}) do
    msg
  end

  defp error_message({:http_error, status, _}) when status >= 400 do
    "Server error (#{status})"
  end

  defp error_message(:rate_limited) do
    "Too many requests. Please wait a moment and try again."
  end

  defp error_message(:timeout) do
    "Connection timed out. Check your Haven server URL."
  end

  defp error_message({:connection_error, reason}) do
    "Connection error: #{reason}"
  end

  defp error_message(:invalid_response) do
    "Unexpected response from Haven server"
  end

  defp error_message(reason) do
    "Error: #{inspect(reason)}"
  end

  defp default_server_url do
    Application.get_env(:soundboard, :haven_server_url, "")
  end
end
