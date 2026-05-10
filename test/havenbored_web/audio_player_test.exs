defmodule Havenbored.AudioPlayerTest do
  use ExUnit.Case, async: false

  import Mock

  alias Havenbored.AudioPlayer
  alias Havenbored.AudioPlayer.State

  @moduletag :capture_log

   setup do
     Application.put_env(:soundboard, :haven_webhook_token, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
     on_exit(fn ->
       Application.delete_env(:soundboard, :haven_webhook_token)
     end)
     on_exit(fn ->
       # Reset the audio player state after each test
       if Process.whereis(AudioPlayer) do
         :sys.replace_state(AudioPlayer, fn _ ->
           %State{
             current_playback: nil,
             pending_request: nil,
             interrupting: false,
             interrupt_watchdog_ref: nil,
             interrupt_watchdog_attempt: 0
           }
         end)
       end
     end)
 
     :ok
   end

  describe "play_sound/2" do
    test "queues and plays a sound via Haven webhook" do
      with_mocks([
        {Havenbored.AudioPlayer.SoundLibrary, [],
         [get_sound_path: fn "test.mp3" -> {:ok, {"/path/test.mp3", 1.0}} end]},
        {Havenbored.Haven.WebhookClient, [],
         [play_sound: fn "test.mp3" -> :ok end]}
      ]) do
        AudioPlayer.play_sound("test.mp3", "actor")

        # Give the task time to start
        Process.sleep(50)

        state = :sys.get_state(AudioPlayer)
        assert state.current_playback != nil
        assert state.current_playback.sound_name == "test.mp3"
      end
    end

    test "returns error when sound is not found" do
      with_mock Havenbored.AudioPlayer.SoundLibrary,
        get_sound_path: fn "missing.mp3" -> {:error, "Sound not found"} end do
        AudioPlayer.play_sound("missing.mp3", "actor")
        Process.sleep(50)

        state = :sys.get_state(AudioPlayer)
        assert state.current_playback == nil
      end
    end
  end

  describe "stop_sound/0" do
    test "clears the playback queue" do
      with_mocks([
        {Havenbored.AudioPlayer.SoundLibrary, [],
         [get_sound_path: fn "test.mp3" -> {:ok, {"/path/test.mp3", 1.0}} end]},
        {Havenbored.Haven.WebhookClient, [],
         [play_sound: fn _ -> :ok end]}
      ]) do
        AudioPlayer.play_sound("test.mp3", "actor")
        Process.sleep(50)

        AudioPlayer.stop_sound()
        Process.sleep(50)

        state = :sys.get_state(AudioPlayer)
        assert state.current_playback == nil
        assert state.pending_request == nil
      end
    end
  end

  describe "current_voice_channel/0" do
    test "always returns {:ok, nil} for Haven (no voice channels)" do
      assert {:ok, nil} == AudioPlayer.current_voice_channel()
    end
  end

  describe "invalidate_cache/1" do
    test "delegates to SoundLibrary" do
      with_mock Havenbored.AudioPlayer.SoundLibrary,
        invalidate_cache: fn "test.mp3" -> :ok end do
        AudioPlayer.invalidate_cache("test.mp3")
        assert called(Havenbored.AudioPlayer.SoundLibrary.invalidate_cache("test.mp3"))
      end
    end
  end

  describe "queue management" do
    test "queues a pending sound when one is already playing" do
      with_mocks([
        {Havenbored.AudioPlayer.SoundLibrary, [],
         [
           get_sound_path: fn "first.mp3" -> {:ok, {"/path/first.mp3", 1.0}} end,
           get_sound_path: fn "second.mp3" -> {:ok, {"/path/second.mp3", 1.0}} end
         ]},
        {Havenbored.Haven.WebhookClient, [],
         [play_sound: fn _ -> :ok end]}
      ]) do
        AudioPlayer.play_sound("first.mp3", "actor")
        Process.sleep(50)

        AudioPlayer.play_sound("second.mp3", "actor")
        Process.sleep(50)

        state = :sys.get_state(AudioPlayer)
        assert state.current_playback.sound_name == "first.mp3"
        assert state.pending_request.sound_name == "second.mp3"
      end
    end
  end
end
