defmodule HavenboredWeb.Live.Support.SoundPlayback do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Havenbored.Accounts.User

  def play(socket, sound_name) do
    case socket.assigns[:current_user] do
      %User{} = user ->
        Havenbored.AudioPlayer.play_sound(sound_name, user)
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "You must be logged in to play sounds")}
    end
  end

  def current_username(socket) do
    case socket.assigns[:current_user] do
      %User{username: username} -> {:ok, username}
      _ -> :error
    end
  end
end
