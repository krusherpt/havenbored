defmodule Soundboard.Haven.Handler do
  @moduledoc """
  Handles Haven webhook events.

  Unlike the Discord handler, this is significantly simpler because:
  - No voice state tracking (Haven webhooks can't detect voice events)
  - No auto-join logic
  - No voice channel presence
  - Sound effects triggered by callbacks or manual commands

  Events received via callback URL:
  - `message` — new message in the webhook's channel
  - `reaction-added` — reaction added to a message
  - `member-joined` — member joined the server

  Slash commands can trigger sound playback via the callback.
  """

  use GenServer

  require Logger

  alias Soundboard.Haven.{Channel, WebhookClient}

  ## Client API

  @doc """
  Dispatch a Haven webhook callback event.
  """
  @spec dispatch_event(event :: map()) :: :ok
  def dispatch_event(%{"event" => event_type} = event) do
    case Process.whereis(__MODULE__) do
      nil ->
        Logger.warning("HavenHandler is not running; dropping event #{event_type}")
        :error

      _pid ->
        GenServer.cast(__MODULE__, {:callback_event, event})
        :ok
    end
  end

  @doc """
  Get the current channel binding.
  """
  @spec get_channel() :: Channel.t() | nil
  def get_channel() do
    GenServer.call(__MODULE__, :get_channel)
  end

  @doc """
  Play a sound through the Haven webhook.
  """
  @spec play_sound(sound_name :: String.t(), actor :: term()) :: :ok | {:error, term()}
  def play_sound(sound_name, actor) do
    GenServer.call(__MODULE__, {:play_sound, sound_name, actor})
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    case load_channel_config() do
      {:ok, channel} ->
        Logger.info("HavenHandler initialized for channel #{channel.channel_code}")
        {:ok, %{channel: channel}}

      :missing ->
        Logger.warning("Haven webhook token not configured; handler will be inactive")
        {:ok, %{channel: nil}}

      {:error, reason} ->
        Logger.error("Failed to initialize HavenHandler: #{inspect(reason)}")
        {:ok, %{channel: nil}}
    end
  end

  @impl true
  def handle_cast({:callback_event, %{"event" => "message"} = event}, state) do
    handle_message_event(event, state)
    {:noreply, state}
  end

  def handle_cast({:callback_event, %{"event" => "reaction-added"} = event}, state) do
    handle_reaction_event(event, state)
    {:noreply, state}
  end

  def handle_cast({:callback_event, %{"event" => "member-joined"} = event}, state) do
    handle_member_join_event(event, state)
    {:noreply, state}
  end

  def handle_cast({:callback_event, event}, state) do
    Logger.debug("Unhandled Haven event type: #{inspect(Map.get(event, "event"))}")
    {:noreply, state}
  end

  def handle_call(:get_channel, _from, %{channel: channel}) do
    {:reply, {:ok, channel}, state}
  end

  def handle_call({:play_sound, sound_name, actor}, _from, %{channel: nil}) do
    {:reply, {:error, :not_configured}, state}
  end

  def handle_call({:play_sound, sound_name, _actor}, _from, %{channel: channel}) do
    case WebhookClient.play_sound(channel.webhook_token, sound_name) do
      :ok ->
        Soundboard.AudioPlayer.Notifier.sound_played(sound_name, "Haven")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to play sound via Haven: #{inspect(reason)}")
        Soundboard.AudioPlayer.Notifier.error("Failed to play sound: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  ## Event handlers

  defp handle_message_event(%{"message" => %{"content" => content} = msg} = event, state) do
    author = Map.get(event, "message", %{}) |> Map.get("author", %{})
    author_name = Map.get(author, "username", "Unknown")

    Logger.debug("Message from #{author_name}: #{inspect(content)}")

    # Check for slash commands
    case parse_slash_command(content) do
      {:sound, sound_name} ->
        play_sound_from_command(sound_name, author_name)

      nil ->
        :ok
    end
  end

  defp handle_message_event(_event, _state), do: :ok

  defp handle_reaction_event(%{"message" => %{"content" => content}}, _state) do
    # Reaction-based triggers could be added here
    Logger.debug("Reaction event received")
    :ok
  end

  defp handle_reaction_event(_event, _state), do: :ok

  defp handle_member_join_event(%{"member" => %{"username" => username}}, _state) do
    Logger.info("Member joined: #{username}")
    # Could play a join sound if desired
    :ok
  end

  defp handle_member_join_event(_event, _state), do: :ok

  defp parse_slash_command("play " <> sound_name) when byte_size(sound_name) > 0 do
    {:sound, String.trim(sound_name)}
  end

  defp parse_slash_command("/play " <> sound_name) when byte_size(sound_name) > 0 do
    {:sound, String.trim(sound_name)}
  end

  defp parse_slash_command(_), do: nil

  defp play_sound_from_command(sound_name, _actor) do
    case Process.whereis(Soundboard.Haven.WebhookClient) do
      nil ->
        Logger.warning("WebhookClient not running")

      _pid ->
        # Use the channel's webhook token to play the sound
        channel = Soundboard.Haven.Handler.get_channel()
        if channel, do: WebhookClient.play_sound(channel.webhook_token, sound_name)
    end
  end

  ## Config helpers

  defp load_channel_config() do
    webhook_token = Application.get_env(:soundboard, :haven_webhook_token)
    channel_code = Application.get_env(:soundboard, :haven_channel_code)

    cond do
      is_nil(webhook_token) or is_nil(channel_code) -> :missing
      true -> Channel.new(webhook_token, channel_code)
    end
  end
end
