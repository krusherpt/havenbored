defmodule Soundboard.Haven.ChannelTest do
  use ExUnit.Case, async: true

  alias Soundboard.Haven.Channel

  describe "valid_webhook_token?/1" do
    test "valid 64-char hex token" do
      assert Channel.valid_webhook_token?("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    end

    test "rejects too short" do
      refute Channel.valid_webhook_token?("0123456789abcdef")
    end

    test "rejects non-hex characters" do
      refute Channel.valid_webhook_token?("gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg")
    end

    test "rejects nil" do
      refute Channel.valid_webhook_token?(nil)
    end

    test "rejects empty string" do
      refute Channel.valid_webhook_token?("")
    end
  end

  describe "valid_channel_code?/1" do
    test "valid 8-char hex code" do
      assert Channel.valid_channel_code?("a1b2c3d4")
    end

    test "rejects too short" do
      refute Channel.valid_channel_code?("a1b2c3")
    end

    test "rejects non-hex characters" do
      refute Channel.valid_channel_code?("gggggggg")
    end
  end

  describe "new/2" do
    test "creates channel from valid inputs" do
      assert {:ok, %Channel{webhook_token: token, channel_code: code}} =
               Channel.new(
                 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                 "a1b2c3d4"
               )

      assert token == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      assert code == "a1b2c3d4"
    end

    test "rejects invalid webhook token" do
      assert {:error, :invalid_webhook_token} =
               Channel.new("too_short", "a1b2c3d4")
    end

    test "rejects invalid channel code" do
      assert {:error, :invalid_channel_code} =
               Channel.new(
                 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                 "bad"
               )
    end
  end

  describe "webhook_token/1 and channel_code/1" do
    test "accessors return correct values" do
      {:ok, channel} =
        Channel.new(
          "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "a1b2c3d4"
        )

      assert Channel.webhook_token(channel) == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      assert Channel.channel_code(channel) == "a1b2c3d4"
    end
  end
end
