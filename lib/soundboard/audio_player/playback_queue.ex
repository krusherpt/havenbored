defmodule Soundboard.AudioPlayer.PlaybackQueue do
  @moduledoc false

  require Logger

  alias Soundboard.AudioPlayer.{Notifier, SoundLibrary, State}
  alias Soundboard.Haven.WebhookClient

  @type play_request :: %{
          sound_name: String.t(),
          path_or_url: String.t(),
          volume: number(),
          actor: term()
        }

  @spec build_request(String.t(), term()) :: {:ok, play_request()} | {:error, String.t()}
  def build_request(sound_name, actor) do
    case SoundLibrary.get_sound_path(sound_name) do
      {:ok, {path_or_url, volume}} ->
        {:ok,
         %{
           sound_name: sound_name,
           path_or_url: path_or_url,
           volume: volume,
           actor: actor
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec enqueue(State.t(), play_request()) :: State.t()
  def enqueue(%State{} = state, request) do
    case state.current_playback do
      nil ->
        state
        |> cancel_interrupt_watchdog()
        |> Map.merge(%{interrupting: false, interrupt_watchdog_attempt: 0})
        |> start_playback(request)

      _ ->
        state
        |> Map.put(:pending_request, request)
        |> maybe_interrupt_current()
    end
  end

  @spec clear_all(State.t()) :: State.t()
  def clear_all(%State{} = state) do
    state
    |> clear_current_playback()
    |> Map.merge(%{
      pending_request: nil,
      interrupting: false,
      interrupt_watchdog_attempt: 0
    })
  end

  @spec handle_task_result(State.t(), term()) :: State.t()
  def handle_task_result(
        %State{current_playback: %{sound_name: sound_name} = current} = state,
        result
      ) do
    case result do
      :ok ->
        %{
          state
          | current_playback:
              current
              |> Map.put(:task_ref, nil)
              |> Map.put(:task_pid, nil)
        }

      :error ->
        Logger.error("Playback start failed for #{sound_name}")
        state |> clear_current_playback() |> maybe_start_pending()
    end
  end

  @spec handle_task_down(State.t(), term()) :: State.t()
  def handle_task_down(%State{} = state, reason) do
    Logger.error("Playback task crashed: #{inspect(reason)}")
    state |> clear_current_playback() |> maybe_start_pending()
  end

  @spec handle_interrupt_watchdog(
          State.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          State.t()
  def handle_interrupt_watchdog(
        %State{interrupting: true, interrupt_watchdog_attempt: attempt} = state,
        attempt,
        max_attempts,
        interrupt_watchdog_ms
      ) do
    cond do
      state.current_playback == nil ->
        state |> reset_interrupt_state() |> maybe_start_pending()

      attempt >= max_attempts ->
        Logger.warning("Interrupt watchdog timed out; forcing latest request")

        state |> clear_current_playback() |> maybe_start_pending()

      true ->
        Logger.debug("Interrupt watchdog: retrying stop")
        schedule_interrupt_watchdog(state, attempt + 1, interrupt_watchdog_ms)
    end
  end

  def handle_interrupt_watchdog(%State{} = state, _attempt, _max_attempts, _delay_ms),
    do: state

  defp start_playback(state, request) do
    task =
      Task.async(fn ->
        play_sound_haven(request.sound_name, request.actor)
      end)

    %{
      state
      | current_playback: request |> Map.put(:task_ref, task.ref) |> Map.put(:task_pid, task.pid)
    }
  end

   defp play_sound_haven(sound_name, _actor) do
     webhook_token = Application.fetch_env!(:soundboard, :haven_webhook_token)
     case WebhookClient.play_sound(webhook_token, sound_name) do
       :ok -> :ok
       {:error, reason} -> {:error, reason}
     end
   rescue
     error -> {:error, Exception.message(error)}
   catch
     :exit, reason -> {:error, reason}
   end

  defp maybe_interrupt_current(%State{current_playback: current} = state) when not is_nil(current) do
    Logger.debug("Interrupting current playback for latest request")

    state
    |> Map.put(:interrupting, true)
    |> schedule_interrupt_watchdog(1, @interrupt_watchdog_ms)
  end

  defp maybe_interrupt_current(%State{} = state), do: state

  defp maybe_start_pending(%State{pending_request: nil} = state), do: state

  defp maybe_start_pending(%State{} = state) do
    request = state.pending_request
    state
    |> Map.put(:pending_request, nil)
    |> start_playback(request)
  end

  defp clear_current_playback(%State{} = state) do
    cancel_playback_task(state.current_playback)

    state
    |> cancel_interrupt_watchdog()
    |> Map.merge(%{
      current_playback: nil,
      interrupting: false,
      interrupt_watchdog_attempt: 0
    })
  end

  defp reset_interrupt_state(%State{} = state) do
    state
    |> cancel_interrupt_watchdog()
    |> Map.merge(%{interrupting: false, interrupt_watchdog_attempt: 0})
  end

  defp schedule_interrupt_watchdog(%State{} = state, attempt, delay_ms) do
    state = cancel_interrupt_watchdog(state)

    ref = Process.send_after(self(), {:interrupt_watchdog, attempt}, delay_ms)

    %{state | interrupt_watchdog_ref: ref, interrupt_watchdog_attempt: attempt}
  end

  defp cancel_interrupt_watchdog(%State{interrupt_watchdog_ref: nil} = state), do: state

  defp cancel_interrupt_watchdog(%State{} = state) do
    Process.cancel_timer(state.interrupt_watchdog_ref)
    %{state | interrupt_watchdog_ref: nil}
  end

  defp cancel_playback_task(nil), do: :ok

  defp cancel_playback_task(%{task_pid: pid, task_ref: ref}) when is_pid(pid) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  defp cancel_playback_task(_), do: :ok
end
