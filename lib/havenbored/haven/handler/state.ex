defmodule Havenbored.Haven.Handler.State do
  @moduledoc """
  Manages the Haven handler's channel binding state.

  Unlike the Discord handler, there is no voice state tracking.
  This module simply holds the channel binding configuration.
  """

  use GenServer

  alias Havenbored.Haven.Channel

  @doc """
  Start the state supervisor.
  """
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Get the current channel binding.
  """
  @spec get_channel() :: Channel.t() | nil
  def get_channel() do
    GenServer.call(__MODULE__, :get_channel)
  end

  @impl true
  def init(_opts) do
    channel = load_channel()
    {:ok, %{channel: channel}}
  end

  @impl true
  def handle_call(:get_channel, _from, %{channel: channel}) do
    {:reply, {:ok, channel}, state}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  defp load_channel() do
    webhook_token = Application.get_env(:soundboard, :haven_webhook_token)
    channel_code = Application.get_env(:soundboard, :haven_channel_code)

    case Channel.new(webhook_token, channel_code) do
      {:ok, channel} -> channel
      _ -> nil
    end
  end
end
