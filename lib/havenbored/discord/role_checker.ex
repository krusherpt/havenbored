defmodule Havenbored.Discord.RoleChecker do
  @moduledoc false

  # Haven migration: Role checking is disabled.
  # All authenticated users have access.
  # This module is kept as a compatibility shim for the auth layer.

  @doc """
  Always returns true — role checking is disabled for Haven.
  """
  @spec feature_enabled?() :: boolean()
  def feature_enabled?(), do: false

  @doc """
  Always returns true — role checking is disabled for Haven.
  """
  @spec authorized?(String.t()) :: boolean()
  def authorized?(_discord_id), do: true
end
