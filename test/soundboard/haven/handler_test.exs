defmodule Soundboard.Haven.HandlerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  @valid_token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  setup do
    Application.put_env(:soundboard, :haven_server_url, "http://localhost:9999")
    Application.put_env(:soundboard, :haven_webhook_token, @valid_token)
    Application.put_env(:soundboard, :haven_channel_code, "a1b2c3d4")

    on_exit(fn ->
      Application.delete_env(:soundboard, :haven_server_url)
      Application.delete_env(:soundboard, :haven_webhook_token)
      Application.delete_env(:soundboard, :haven_channel_code)
    end)

    :ok
  end

  describe "dispatch_event/1" do
    test "accepts message events" do
      assert :ok ==
               Soundboard.Haven.Handler.dispatch_event(%{
                 "event" => "message",
                 "message" => %{
                   "content" => "Hello world",
                   "author" => %{"username" => "test_user"}
                 }
               })
    end

    test "accepts reaction events" do
      assert :ok ==
               Soundboard.Haven.Handler.dispatch_event(%{
                 "event" => "reaction-added",
                 "message" => %{"content" => "test"}
               })
    end

    test "accepts member-joined events" do
      assert :ok ==
               Soundboard.Haven.Handler.dispatch_event(%{
                 "event" => "member-joined",
                 "member" => %{"username" => "new_user"}
               })
    end

    test "returns error when handler is not running" do
      # Stop the handler if it's running
      Process.exit(Process.whereis(Soundboard.Haven.Handler), :kill)
      :timer.sleep(100)

      assert :error ==
               Soundboard.Haven.Handler.dispatch_event(%{
                 "event" => "message",
                 "message" => %{"content" => "test"}
               })
    end
  end

  describe "get_channel/0" do
    test "returns the configured channel" do
      assert {:ok, channel} = Soundboard.Haven.Handler.get_channel()
      assert channel.webhook_token == @valid_token
      assert channel.channel_code == "a1b2c3d4"
    end
  end

  describe "play_sound/2" do
    test "returns :error when webhook is not configured" do
      Application.put_env(:soundboard, :haven_webhook_token, nil)
      Application.put_env(:soundboard, :haven_channel_code, nil)

      # Restart handler with no config
      Soundboard.Haven.Handler.stop()
      :timer.sleep(100)
      {:ok, _pid} = GenServer.start_link(Soundboard.Haven.Handler, [])

      assert {:error, :not_configured} == Soundboard.Haven.Handler.play_sound("Test", %{})
    end
  end
end
