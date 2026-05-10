defmodule Soundboard.AudioPlayer do
  @moduledoc """
  Handles audio playback coordination via Haven webhook API.

  Unlike the Discord version, this does not stream audio locally.
  Instead, it triggers sound playback through Haven's webhook API,
  and Haven's clients play the sounds via their `<audio>` tags.

  Key differences from Discord:
  - No voice channel management (Haven webhooks are text-channel-bound)
  - No auto-join logic (Haven can't detect voice presence)
  - No FFmpeg streaming (Haven clients handle playback)
  - Playback is a webhook API call, not a local audio stream
  """

  use GenServer

  require Logger

  alias Soundboard.AudioPlayer.{Notifier, PlaybackQueue, SoundLibrary}
  alias Soundboard.Haven.WebhookClient

  @interrupt_watchdog_ms 35
  @interrupt_watchdog_max_attempts 20

  defmodule State do
    @moduledoc """
    The state of the Haven audio player.
    """

    defstruct [
      :current_playback,
      :pending_request,
      :interrupting,
      :interrupt_watchdog_ref,
      :interrupt_watchdog_attempt
    ]

    @type t :: %__MODULE__{
            current_playback: map() | nil,
            pending_request: map() | nil,
            interrupting: boolean() | nil,
            interrupt_watchdog_ref: reference() | nil,
            interrupt_watchdog_attempt: non_neg_integer() | nil
          }
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %State{}, name: __MODULE__)
  end

  @doc """
  Play a sound through the Haven webhook.
  """
  @spec play_sound(sound_name :: String.t(), actor :: term()) :: :ok | {:error, term()}
  def play_sound(sound_name, actor) do
    GenServer.cast(__MODULE__, {:play_sound, sound_name, actor})
  end

  @doc """
  Stop current playback and clear the queue.
  """
  @spec stop_sound() :: :ok
  def stop_sound do
    GenServer.cast(__MODULE__, :stop_sound)
  end

  @doc """
  Get the current voice channel (deprecated for Haven, returns nil).
  """
  @spec current_voice_channel() :: {:ok, nil} | {:error, term()}
  def current_voice_channel do
    {:ok, nil}
  end

  @doc """
  Removes any cached metadata for the given `sound_name` so future plays use fresh data.
  """
  @spec invalidate_cache(sound_name :: String.t()) :: :ok
  def invalidate_cache(sound_name), do: SoundLibrary.invalidate_cache(sound_name)

  @impl true
  def init(state) do
    SoundLibrary.ensure_cache()

    {:ok,
     %{
       state
       | current_playback: nil,
         pending_request: nil,
         interrupting: false,
         interrupt_watchdog_ref: nil,
         interrupt_watchdog_attempt: 0
     }}
  end

  @impl true
  def handle_cast({:play_sound, sound_name, actor}, state) do
    do_play_sound(sound_name, actor, state)
  end

  def handle_cast(:stop_sound, state) do
    Notifier.sound_played("All sounds stopped", "System")
    {:noreply, PlaybackQueue.clear_all(state)}
  end

  @impl true
  def handle_call(:get_voice_channel, _from, state) do
    {:reply, {:ok, nil}, state}
  end

  @impl true
  def handle_info(
        {:interrupt_watchdog, attempt},
        %{interrupting: true, interrupt_watchdog_attempt: attempt} = state
      ) do
    {:noreply,
     PlaybackQueue.handle_interrupt_watchdog(
       state,
       attempt,
       @interrupt_watchdog_max_attempts,
       @interrupt_watchdog_ms
     )}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Internal functions

  defp do_play_sound(sound_name, actor, %{voice_channel: nil} = state) do
    # Haven doesn't have voice channels — just play via webhook
    case PlaybackQueue.build_request(sound_name, actor) do
      {:ok, request} ->
        {:noreply, PlaybackQueue.enqueue(state, request)}

      {:error, reason} ->
        Notifier.error(reason)
        {:noreply, state}
    end
  end

  defp do_play_sound(sound_name, actor, state) do
    case PlaybackQueue.build_request(sound_name, actor) do
      {:ok, request} ->
        {:noreply, PlaybackQueue.enqueue(state, request)}

      {:error, reason} ->
        Notifier.error(reason)
        {:noreply, state}
    end
  end
end
