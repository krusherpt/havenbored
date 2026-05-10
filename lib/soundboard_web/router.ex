defmodule SoundboardWeb.Router do
  use SoundboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SoundboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_basic_auth do
    plug SoundboardWeb.Plugs.BasicAuth
  end

  pipeline :auth do
    plug :fetch_session
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug SoundboardWeb.Plugs.APIAuth
  end

  # Auth routes (login/register/TOTP)
  scope "/auth", SoundboardWeb do
    pipe_through [:browser]

    get "/login", AuthController, :login
     get "/totp", AuthController, :totp
    post "/login", AuthController, :login_post
     post "/totp", AuthController, :totp_post
    delete "/logout", AuthController, :logout
  end

  # Protected routes (require Basic Auth + session)
  scope "/", SoundboardWeb do
    pipe_through [
      :browser,
      :require_basic_auth,
      :auth,
      :ensure_authenticated_user
    ]

    live "/", SoundboardLive
    live "/stats", StatsLive
    live "/favorites", FavoritesLive
    live "/settings", SettingsLive
  end

  scope "/uploads" do
    pipe_through [
      :browser,
      :require_basic_auth,
      :auth,
      :ensure_authenticated_user
    ]

    get "/*path", SoundboardWeb.UploadController, :show
  end

  if Mix.env() == :test do
    scope "/debug", SoundboardWeb do
      pipe_through [:browser]

      get "/session", AuthController, :debug_session
    end
  end

  # API routes (require API token)
  scope "/api", SoundboardWeb.API do
    pipe_through :api

    get "/sounds", SoundController, :index
    post "/sounds", SoundController, :create
    post "/sounds/:id/play", SoundController, :play
    post "/sounds/stop", SoundController, :stop
  end

  ## Session helpers

  def fetch_current_user(conn, _) do
    user_id = get_session(conn, :haven_user_id)

    if user_id do
      conn
      |> assign(:current_user, %{id: user_id, username: get_session(conn, :haven_username)})
    else
      assign(conn, :current_user, nil)
    end
  end

  def ensure_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_session(:return_to, conn.request_path)
      |> redirect(to: "/auth/login")
      |> halt()
    end
  end
end
