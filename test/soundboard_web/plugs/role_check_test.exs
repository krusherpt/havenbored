defmodule SoundboardWeb.Plugs.RoleCheckTest do
  use SoundboardWeb.ConnCase, async: false

  alias Soundboard.Accounts.User
  alias Soundboard.Repo
  alias SoundboardWeb.Plugs.RoleCheck

  setup do
    Repo.delete_all(User)
    {:ok, user: insert_user()}
  end

  defp insert_user do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        username: "testuser#{System.unique_integer([:positive])}",
        discord_id: nil,
        avatar: nil
      })
      |> Repo.insert()

    user
  end

  describe "RoleCheck plug (Haven migration)" do
    test "always passes through — no role checking for Haven", %{conn: conn} do
      result =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> fetch_flash()
        |> RoleCheck.call(RoleCheck.init([]))

      refute result.halted
    end

    test "passes through even without a current_user assigned", %{conn: conn} do
      result =
        conn
        |> init_test_session(%{})
        |> fetch_session()
        |> fetch_flash()
        |> RoleCheck.call(RoleCheck.init([]))

      refute result.halted
    end

    test "passes through with a current_user assigned", %{conn: conn, user: user} do
      result =
        conn
        |> init_test_session(%{user_id: user.id})
        |> fetch_session()
        |> fetch_flash()
        |> assign(:current_user, user)
        |> RoleCheck.call(RoleCheck.init([]))

      refute result.halted
      assert result.assigns[:current_user] == user
    end
  end
end
