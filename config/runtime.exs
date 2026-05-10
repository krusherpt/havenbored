import Config
import Dotenvy

env_dir_prefix = System.get_env("RELEASE_ROOT") || Path.expand(".")

source!([
  Path.absname(".env", env_dir_prefix),
  Path.absname(".#{config_env()}.env", env_dir_prefix),
  Path.absname(".#{config_env()}.overrides.env", env_dir_prefix),
  System.get_env()
])

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/soundboard start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if env!("PHX_SERVER", :boolean, false) do
  config :havenbored, SoundboardWeb.Endpoint, server: true
end

 if config_env() == :dev do
   host = env!("PHX_HOST", :string!, "localhost:4000")
   scheme = env!("SCHEME", :string!, "http")
   port = env!("PORT", :integer, 4000)
 
   secret_key_base =
     case env!("SECRET_KEY_BASE", :string!, nil) do
       value when is_binary(value) and byte_size(value) >= 64 ->
         value
 
       value when is_binary(value) ->
         :crypto.hash(:sha512, value)
         |> Base.encode64(padding: false)
 
       _ ->
         nil
     end
 
   bind_ip =
     case env!("BIND_IP", :string!, "127.0.0.1")
          |> String.to_charlist()
          |> :inet.parse_address() do
       {:ok, ip_tuple} -> ip_tuple
       _ -> {127, 0, 0, 1}
     end
 
   endpoint_overrides = [
     url: [host: host, port: port, scheme: scheme],
     http: [ip: bind_ip, port: port]
   ]
 
   endpoint_overrides =
     if is_binary(secret_key_base) do
       Keyword.put(endpoint_overrides, :secret_key_base, secret_key_base)
     else
       endpoint_overrides
     end
 
   config :havenbored, SoundboardWeb.Endpoint, endpoint_overrides
 
   # Configure Haven
   haven_server_url = env!("HAVEN_SERVER_URL", :string, nil)
   haven_webhook_token = env!("HAVEN_WEBHOOK_TOKEN", :string, nil)
   haven_channel_code = env!("HAVEN_CHANNEL_CODE", :string, nil)
   haven_request_timeout_ms = env!("HAVEN_REQUEST_TIMEOUT_MS", :integer, 10_000)
 
   if is_nil(haven_server_url) or is_nil(haven_webhook_token) or is_nil(haven_channel_code) do
     IO.warn(
       "Haven configuration is incomplete. Set HAVEN_SERVER_URL, HAVEN_WEBHOOK_TOKEN, and HAVEN_CHANNEL_CODE."
     )
   end
 
   config :havenbored,
     haven_server_url: haven_server_url,
     haven_webhook_token: haven_webhook_token,
     haven_channel_code: haven_channel_code,
     haven_request_timeout_ms: haven_request_timeout_ms
 end

# Allow build tooling to opt-out to avoid requiring secrets during image builds.
 if config_env() == :prod and is_nil(env!("SKIP_RUNTIME_CONFIG", :string, nil)) do
   port = env!("PORT", :integer, 4000)
 
   # Replace the database_url section with SQLite configuration
   database_path = Path.join(:code.priv_dir(:havenbored), "static/uploads/soundboard_prod.db")
 
   config :havenbored, Soundboard.Repo,
     database: database_path,
     adapter: Ecto.Adapters.SQLite3,
     pool_size: env!("POOL_SIZE", :integer, 10)
 
   # The secret key base is used to sign/encrypt cookies and other secrets.
   secret_key_base =
     case env!("SECRET_KEY_BASE", :string!, nil) do
       value when is_binary(value) ->
         value
 
       _ ->
         case env!("SECRET_KEY_BASE_FILE", :string!, nil) do
           file when is_binary(file) ->
             case File.read(file) do
               {:ok, key} ->
                 String.trim(key)
 
               {:error, reason} ->
                 raise """
                 could not read SECRET_KEY_BASE_FILE (#{file}): #{inspect(reason)}
                 """
             end
 
           _ ->
             raise """
             environment variable SECRET_KEY_BASE is missing.
             Provide it via your environment (recommended) or set SECRET_KEY_BASE_FILE to a file path containing the key.
             Generate one with: mix phx.gen.secret OR openssl rand -base64 48
             """
         end
     end
 
   host = env!("PHX_HOST", :string!)
   scheme = env!("SCHEME", :string!, "https")
 
   # Configure endpoint
   config :havenbored, SoundboardWeb.Endpoint,
     url: [
       scheme: scheme,
       host: host,
       port: nil
     ],
     http: [
       ip: {0, 0, 0, 0},
       port: port
     ],
     static_url: [
       host: host,
       port: nil
     ],
     check_origin: false,
     force_ssl: scheme == "https",
     secret_key_base: secret_key_base,
     session: [
       store: :cookie,
       key: "_soundboard_key",
       signing_salt: secret_key_base
     ]
 
   # Configure Haven
   haven_server_url = env!("HAVEN_SERVER_URL", :string!)
   haven_webhook_token = env!("HAVEN_WEBHOOK_TOKEN", :string!)
   haven_channel_code = env!("HAVEN_CHANNEL_CODE", :string!)
   haven_request_timeout_ms = env!("HAVEN_REQUEST_TIMEOUT_MS", :integer, 10_000)
 
   config :havenbored,
     haven_server_url: haven_server_url,
     haven_webhook_token: haven_webhook_token,
     haven_channel_code: haven_channel_code,
     haven_request_timeout_ms: haven_request_timeout_ms
 
   # Configure logger for production
   config :logger,
     level: :debug,
     compile_time_purge_matching: [
       [level_lower_than: :debug]
     ]
 
   config :logger, :console,
     format: "$time $metadata[$level] $message\n",
     metadata: [:request_id, :error],
     colors: [enabled: true]
 
   # Keep stacktraces in production for better error reporting
   config :phoenix,
     stacktrace_depth: 20,
     plug_init_mode: :runtime
 
   config :havenbored, :env, :prod
 end
