defmodule Soundboard.AudioPlayer.VoiceSession do
  @moduledoc false

  # Haven doesn't have voice channels. This module is kept as a compatibility shim
  # for code that references it, but all operations are no-ops.

  alias Soundboard.AudioPlayer.State

  @spec normalize_channel(term(), term()) :: nil
  def normalize_channel(_guild_id, _channel_id), do: nil

  @spec maintain_connection(State.t()) :: State.t()
  def maintain_connection(state), do: state
end
