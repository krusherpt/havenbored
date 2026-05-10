defmodule Havenbored.Haven.WebhookClient do
  @moduledoc """
  HTTP client for the Haven webhook API.

  Provides functions to interact with Haven's webhook endpoints:
  - Sending messages
  - Playing sounds
  - Deleting messages
  - Registering slash commands

  All endpoints are rate-limited to 30 requests per minute per IP.
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

  @type success_response() :: %{success: true} | %{success: true, message_id: integer()}

  ## Client API

  @doc """
  Play a sound through the Haven webhook.

  Sends a `play-sound` Socket.IO event to all clients in the webhook's channel.
  """
  @spec play_sound(webhook_token :: String.t(), sound_name :: String.t()) ::
          :ok | {:error, error_reason()}
  def play_sound(webhook_token, sound_name) do
    GenServer.call(__MODULE__, {:play_sound, webhook_token, sound_name})
  end

  @doc """
  Send a message to the webhook's text channel.
  """
  @spec send_message(webhook_token :: String.t(), text :: String.t()) ::
          :ok | {:error, error_reason()}
  def send_message(webhook_token, text) when is_binary(text) and byte_size(text) > 0 do
    GenServer.call(__MODULE__, {:send_message, webhook_token, text})
  end

  @doc """
  Send a message with optional overrides (username, avatar, reply).
  """
  @spec send_message(
          webhook_token :: String.t(),
          text :: String.t(),
          opts :: [username: String.t(), avatar_url: String.t(), reply_to: integer()]
        ) ::
          :ok | {:error, error_reason()}
  def send_message(webhook_token, text, opts)
      when is_binary(text) and byte_size(text) > 0 and is_list(opts) do
    GenServer.call(__MODULE__, {:send_message, webhook_token, text, opts})
  end

  @doc """
  Delete a message from the webhook's text channel.
  """
  @spec delete_message(webhook_token :: String.t(), message_id :: integer()) ::
          :ok | {:error, error_reason()}
  def delete_message(webhook_token, message_id) when is_integer(message_id) and message_id > 0 do
    GenServer.call(__MODULE__, {:delete_message, webhook_token, message_id})
  end

  @doc """
  Register a slash command for the webhook.
  """
  @spec register_command(
          webhook_token :: String.t(),
          command :: String.t(),
          description :: String.t()
        ) ::
          :ok | {:error, error_reason()}
  def register_command(webhook_token, command, description) do
    GenServer.call(__MODULE__, {:register_command, webhook_token, command, description})
  end

  @doc """
  List available sounds. Requires an authenticated user token.
  """
  @spec list_sounds(user_token :: String.t()) :: [String.t()] | {:error, error_reason()}
  def list_sounds(user_token) when is_binary(user_token) and byte_size(user_token) > 0 do
    GenServer.call(__MODULE__, {:list_sounds, user_token})
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:play_sound, webhook_token, sound_name}, _from, state) do
    base_url = base_url()
    url = "#{base_url}/api/webhooks/#{webhook_token}/sounds"

    body = Jason.encode!(%{"sound" => sound_name})

    case make_request(:post, url, body, webhook_auth_header(webhook_token)) do
       {:ok, %{status: 200, body: %{"success" => true}}} -> :ok
      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Jason.encode!(body)}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:send_message, webhook_token, text, opts}, _from, state) do
    base_url = base_url()
    url = "#{base_url}/api/webhooks/#{webhook_token}"

    body = build_message_body(text, opts)

    case make_request(:post, url, Jason.encode!(body), webhook_auth_header(webhook_token)) do
       {:ok, %{status: 200, body: %{"success" => true, "message_id" => _}}} -> :ok
      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Jason.encode!(body)}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:send_message, webhook_token, text}, _from, state) do
    handle_call({:send_message, webhook_token, text, []}, _from, state)
  end

  def handle_call({:delete_message, webhook_token, message_id}, _from, state) do
    base_url = base_url()
    url = "#{base_url}/api/webhooks/#{webhook_token}/messages/#{message_id}"

    case make_request(:delete, url, "", webhook_auth_header(webhook_token)) do
       {:ok, %{status: 200, body: %{"success" => true}}} -> :ok
      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Jason.encode!(body)}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:register_command, webhook_token, command, description}, _from, state) do
    base_url = base_url()
    url = "#{base_url}/api/webhooks/#{webhook_token}/commands"

    body = Jason.encode!(%{"command" => command, "description" => description})

    case make_request(:post, url, body, webhook_auth_header(webhook_token)) do
       {:ok, %{status: 200, body: %{"success" => true}}} -> :ok
      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, Jason.encode!(body)}}

      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_call({:list_sounds, user_token}, _from, state) do
    base_url = base_url()
    url = "#{base_url}/api/sounds"

    headers = [{"authorization", "Bearer #{user_token}"}]

    case make_request(:get, url, "", headers) do
      {:ok, %{status: 200, body: body}} ->
        case parse_sounds_response(body) do
          {:ok, sounds} -> {:reply, {:ok, sounds}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:ok, %{status: status, body: body}} ->
        {:reply, {:error, {:http_error, status, Jason.encode!(body)}}, state}

      {:error, :rate_limited} ->
        {:reply, {:error, :rate_limited}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  ## Internal functions

  defp base_url do
    Application.fetch_env!(:soundboard, :haven_server_url)
  end

  defp webhook_auth_header(token) do
    [{"content-type", "application/json"}]
  end

  defp build_message_body(text, opts) do
    base = %{"content" => text}

    base
    |> maybe_put("username", Keyword.get(opts, :username))
    |> maybe_put("avatar_url", Keyword.get(opts, :avatar_url))
    |> maybe_put("reply_to", Keyword.get(opts, :reply_to))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_sounds_response(body) when is_map(body) do
    case Map.fetch(body, "sounds") do
      {:ok, sounds} when is_list(sounds) ->
        {:ok, Enum.map(sounds, &to_string/1)}

      {:ok, other} ->
        Logger.warning("Unexpected sounds response shape: #{inspect(other)}")
        {:error, :invalid_response}

      :error ->
        Logger.warning("Missing 'sounds' key in response: #{inspect(body)}")
        {:error, :invalid_response}
    end
  end

  defp parse_sounds_response(body) do
    Logger.warning("Non-map sounds response: #{inspect(body)}")
    {:error, :invalid_response}
  end

  @doc """
  Make an HTTP request with rate limit detection.
  """
  @spec make_request(
          :get | :post | :delete,
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

  defp request_timeout_ms() do
    Application.fetch_env!(:soundboard, :haven_request_timeout_ms)
  end
end
