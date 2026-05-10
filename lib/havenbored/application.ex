defmodule Havenbored.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Soundboard Application")

    children = [
      Havenbored.Repo,
      {Havenbored.AudioPlayer, []},
      HavenboredWeb.Telemetry,
      {Phoenix.PubSub, name: Havenbored.PubSub},
      HavenboredWeb.Presence,
      HavenboredWeb.PresenceHandler,
      Havenbored.Haven.Handler.State,
      HavenboredWeb.Endpoint,
      Havenbored.Haven.Handler
    ]

    opts = [strategy: :one_for_one, name: Havenbored.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HavenboredWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
