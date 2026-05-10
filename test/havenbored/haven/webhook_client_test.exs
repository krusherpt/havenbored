defmodule Havenbored.Haven.WebhookClientTest do
  use ExUnit.Case, async: false

  alias Havenbored.Haven.WebhookClient

  @valid_token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @test_server_url "http://localhost:9999"

  setup do
    Application.put_env(:soundboard, :haven_server_url, @test_server_url)
    Application.put_env(:soundboard, :haven_request_timeout_ms, 5_000)

    on_exit(fn ->
      Application.delete_env(:soundboard, :haven_server_url)
      Application.delete_env(:soundboard, :haven_request_timeout_ms)
    end)

    :ok
  end

  describe "play_sound/2" do
    test "returns :ok on successful response" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"success" => true})
         }}
      end)

      assert WebhookClient.play_sound(@valid_token, "Test Sound") == :ok
    end

    test "returns error on HTTP error" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 404,
           headers: [],
           body: Jason.encode!(%{"error" => "Not found"})
         }}
      end)

      assert {:error, {:http_error, 404, _}} = WebhookClient.play_sound(@valid_token, "Test Sound")
    end

    test "returns :rate_limited on 429" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:error, %Finch.Status{:code => 429}}
      end)

      assert WebhookClient.play_sound(@valid_token, "Test Sound") == {:error, :rate_limited}
    end
  end

  describe "send_message/2" do
    test "returns :ok on successful response" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"success" => true, "message_id" => 123})
         }}
      end)

      assert WebhookClient.send_message(@valid_token, "Hello") == :ok
    end
  end

  describe "delete_message/2" do
    test "returns :ok on successful response" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"success" => true})
         }}
      end)

      assert WebhookClient.delete_message(@valid_token, 123) == :ok
    end
  end

  describe "register_command/3" do
    test "returns :ok on successful response" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"success" => true})
         }}
      end)

      assert WebhookClient.register_command(@valid_token, "play", "Play a sound") == :ok
    end
  end

  describe "list_sounds/1" do
    test "returns list of sound names on success" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"sounds" => ["AOL - You've Got Mail", "Ding"]})
         }}
      end)

      assert {:ok, ["AOL - You've Got Mail", "Ding"]} == WebhookClient.list_sounds("user_token_123")
    end

    test "returns error on invalid response shape" do
      Finch.start_link(name: Havenbored.Haven.Finch)

      Mock.expects(Finch, :request, fn _build, _pool, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [],
           body: Jason.encode!(%{"data" => []})
         }}
      end)

      assert {:error, :invalid_response} == WebhookClient.list_sounds("user_token_123")
    end
  end
end
