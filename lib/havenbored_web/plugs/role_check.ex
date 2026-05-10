defmodule HavenboredWeb.Plugs.RoleCheck do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  # Haven migration: Role checking is disabled.
  # All authenticated users have access.

  def init(opts), do: opts

  def call(conn, _opts) do
    # No role checking for Haven — all authenticated users pass through
    conn
  end
end
