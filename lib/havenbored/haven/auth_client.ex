defmodule Havenbored.Haven.AuthClient do
  @moduledoc """
  Client for Haven's authentication API.

  Provides functions to:
  - Log in with username/password
  - Validate TOTP (second factor)
  - Register a new account
  - Validate a JWT token

  API endpoints:
    POST /api/auth/login
    POST /api/auth/totp/validate
    POST /api/auth/register
    GET  /api/auth/validate
  """

  use GenServer

  require Logger

  @type error_reason() ::
          {:http_error, status_code :: pos_integer(), body :: String.t()}
          | :rate_limited
          | :timeout
          | {:connection_error, term()}
          | :invalid_response
          | {:validation_error, term()}

  @type user_info() :: %{
          id: integer(),
          username: String.t(),
          isAdmin: boolean(),
          displayName: String.t()
        }

  @type login_response() ::
          {:ok, token: String.t(), user: user_info()}
          | {:error, error_reason()}
          | {:requires_totp, challenge_token: String.t()}

  @type register_response() ::
          {:ok, token: String.t(), user: user_info()}
          | {:error, error_reason()}

  ## Client API

  @doc """
  Log in with username and password.

  Returns `{:requires_totp, challenge_token}` if TOTP is enabled on the account.
  """
  @spec login(String.t(), String.t(), String.t(), boolean()) :: login_response()
  def login(server_url, username, password, age_verified \\ true) do
    GenServer.call(__MODULE__, {:login, server_url, username, password, age_verified})
  end

  @doc """
  Validate a TOTP code after login returned `:requires_totp`.
  """
  @spec validate_totp(String.t(), String.t(), String.t()) :: login_response()
  def validate_totp(server_url, challenge_token, code) do
    GenServer.call(__MODULE__, {:validate_totp, server_url, challenge_token, code})
  end

  @doc """
  Register a new Haven account.
  """
  @spec register(String.t(), String.t(), String.t(), String.t(), boolean(), String.t() | nil) ::
          register_response()
  def register(server_url, username, password, eula_version, age_verified, registration_token \\ nil) do
    GenServer.call(__MODULE__, {:register, server_url, username, password, eula_version, age_verified, registration_token})
  end

  @doc """
  Validate a Haven JWT token.
  """
  @spec validate_token(String.t(), String.t()) ::
          {:ok, user_info()} | {:error, error_reason()}
  def validate_token(server_url, token) do
    GenServer.call(__MODULE__, {:validate_token, server_url, token})
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:login, server_url, username, password, age_verified}, _from, state) do
    base_url = resolve_server_url(server_url)
    url = "#{base_url}/api/auth/login"

    body = Jason.encode!(%{
      "username" => username,
      "password" => password,
      "eulaVersion" => "1",
      "ageVerified" => age_verified
    })

    case make_request(:post, url, body) do
      {:ok, %{status: 200, body: body}} ->
        handle_login_response(body)

      {:ok, %{status: 401, body: body}} ->
        {:error, {:http_error, 401, Map.get(body, "error", "Invalid credentials")}}

      {:ok, %{status: 403, body: body}} ->
        {:error, {:http_error, 403, Map.get(body, "error", "Banned")}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Map.get(body, "error", "Server error")}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:validate_totp, server_url, challenge_token, code}, _from, state) do
    base_url = resolve_server_url(server_url)
    url = "#{base_url}/api/auth/totp/validate"

    body = Jason.encode!(%{
      "challengeToken" => challenge_token,
      "code" => code
    })

    case make_request(:post, url, body) do
      {:ok, %{status: 200, body: body}} ->
        handle_login_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Map.get(body, "error", "TOTP validation failed")}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:register, server_url, username, password, eula_version, age_verified, registration_token}, _from, state) do
    base_url = resolve_server_url(server_url)
    url = "#{base_url}/api/auth/register"

    body = Jason.encode!(%{
      "username" => username,
      "password" => password,
      "eulaVersion" => eula_version,
      "ageVerified" => age_verified
    })
    |> maybe_put("registrationToken", registration_token)

    case make_request(:post, url, body) do
      {:ok, %{status: 200, body: body}} ->
        handle_login_response(body)

      {:ok, %{status: 400, body: body}} ->
        {:error, {:http_error, 400, Map.get(body, "error", "Registration failed")}}

      {:ok, %{status: 403, body: body}} ->
        {:error, {:http_error, 403, Map.get(body, "error", "Registration restricted")}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Map.get(body, "error", "Server error")}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:validate_token, server_url, token}, _from, state) do
    base_url = resolve_server_url(server_url)
    url = "#{base_url}/api/auth/validate"

    headers = [{"authorization", "Bearer #{token}"}]

    case make_request(:get, url, "", headers) do
      {:ok, %{status: 200, body: body}} ->
        case parse_user_response(body) do
          {:ok, user} -> {:reply, {:ok, user}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:ok, %{status: 401}} ->
        {:reply, {:error, :invalid_token}, state}

      {:ok, %{status: status}} ->
        {:reply, {:error, {:http_error, status, ""}}, state}

      {:error, :rate_limited} ->
        {:reply, {:error, :rate_limited}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  ## Internal functions

  defp resolve_server_url(url) do
    case String.trim(url) do
      "" -> Application.fetch_env!(:soundboard, :haven_server_url)
      u -> u
    end
    |> String.trim_trailing("/")
  end

  defp handle_login_response(%{"requiresTOTP" => true, "challengeToken" => ct}) do
    {:reply, {:requires_totp, challenge_token: ct}, state}
  end

  defp handle_login_response(%{"token" => token, "user" => user}) do
    user_info = %{
      "id" => Map.get(user, "id"),
      "username" => Map.get(user, "username"),
      "isAdmin" => Map.get(user, "isAdmin", false),
      "displayName" => Map.get(user, "displayName", Map.get(user, "username"))
    }
    {:reply, {:ok, token: token, user: user_info}, state}
  end

  defp handle_login_response(body) do
    Logger.warning("Unexpected login response: #{inspect(body)}")
    {:reply, {:error, :invalid_response}, state}
  end

  defp parse_user_response(%{"id" => id, "username" => username, "displayName" => displayName}) do
    {:ok, %{
      id: id,
      username: username,
      isAdmin: false,
      displayName: displayName
    }}
  end

  defp parse_user_response(body) do
    Logger.warning("Unexpected validate response: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Make an HTTP request to Haven's API.
  """
  @spec make_request(
          :get | :post,
          String.t(),
          String.t(),
          [{String.t(), String.t()}]
        ) ::
          {:ok, %{status: pos_integer(), body: map()}} | {:error, error_reason()}
  def make_request(method, url, body, headers \\ []) do
    Finch.build(method, url, headers, body)
    |> Finch.request(Havenbored.Haven.Finch, request_timeout_ms())
    |> handle_response()
  end

  defp handle_response({:ok, %{status: status, body: raw_body}}) do
    case Jason.decode(raw_body) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, %{status: status, body: parsed}}

      {:ok, parsed} when is_list(parsed) ->
        {:ok, %{status: status, body: %{items: parsed}}}

      {:error, _} ->
        {:ok, %{status: status, body: %{"raw" => raw_body}}}

      :error ->
        {:error, :invalid_response}
    end
  end

  defp handle_response({:error, %Finch.Status{:code => 429}}) do
    Logger.warning("Haven API rate limit exceeded (429)")
    {:error, :rate_limited}
  end

  defp handle_response({:error, %Finch.Status{:code => code}}) do
    Logger.warning("Haven API error (#{code})")
    {:error, {:http_error, code, ""}}
  end

  defp handle_response({:error, %Mint.TransportError{reason: :timeout}}) do
    Logger.warning("Haven API request timed out")
    {:error, :timeout}
  end

  defp handle_response({:error, %Mint.TransportError{reason: reason}}) do
    Logger.warning("Haven API connection error: #{inspect(reason)}")
    {:error, {:connection_error, reason}}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("Haven API unexpected error: #{inspect(reason)}")
    {:error, {:connection_error, reason}}
  end

  defp request_timeout_ms do
    Application.fetch_env!(:soundboard, :haven_request_timeout_ms)
  end
end
