defmodule Soundboard.Haven.Channel do
  @moduledoc """
  Represents a Haven channel binding.

  A Haven webhook is bound to a single text channel. This module provides
  validation and representation of that binding.

  Unlike Discord (which uses guild + voice channel), Haven uses:
  - `webhook_token`: 64-character hex string
  - `channel_code`: 8-character hex string (text channel identifier)
  """

  @type t :: %__MODULE__{
          webhook_token: String.t(),
          channel_code: String.t()
        }

  defstruct [:webhook_token, :channel_code]

  @doc """
  Validate a webhook token format.
  """
  @spec valid_webhook_token?(String.t()) :: boolean()
  def valid_webhook_token?(token) do
    is_binary(token) and byte_size(token) == 64 and Regex.match?(~r/^[0-9a-f]{64}$/, token)
  end

  @doc """
  Validate a channel code format.
  """
  @spec valid_channel_code?(String.t()) :: boolean()
  def valid_channel_code?(code) do
    is_binary(code) and byte_size(code) == 8 and Regex.match?(~r/^[0-9a-f]{8}$/, code)
  end

  @doc """
  Create a new channel binding from raw values.
  Returns `:error` if either value is invalid.
  """
  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_webhook_token | :invalid_channel_code}
  def new(webhook_token, channel_code) do
    cond do
      not valid_webhook_token?(webhook_token) -> {:error, :invalid_webhook_token}
      not valid_channel_code?(channel_code) -> {:error, :invalid_channel_code}
      true -> {:ok, %__MODULE__{webhook_token: webhook_token, channel_code: channel_code}}
    end
  end

  @doc """
  Get the webhook token from a channel binding.
  """
  @spec webhook_token(t()) :: String.t()
  def webhook_token(%__MODULE__{webhook_token: token}), do: token

  @doc """
  Get the channel code from a channel binding.
  """
  @spec channel_code(t()) :: String.t()
  def channel_code(%__MODULE__{channel_code: code}), do: code
end
