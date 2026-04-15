defmodule Viche.Telegram.ApiTest do
  use ExUnit.Case, async: true

  alias Viche.Telegram.Api

  setup do
    Req.Test.verify_on_exit!(:telegram_api)
    :ok
  end

  test "get_me/1 returns bot info" do
    Req.Test.expect(:telegram_api, fn conn ->
      assert String.ends_with?(conn.request_path, "/getMe")

      Req.Test.json(conn, %{
        "ok" => true,
        "result" => %{"id" => 123, "username" => "test_bot", "is_bot" => true}
      })
    end)

    assert {:ok, %{"id" => 123, "username" => "test_bot"}} = Api.get_me("fake")
  end

  test "send_message/4 sends reply markup" do
    Req.Test.expect(:telegram_api, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      parsed = Jason.decode!(body)
      assert parsed["reply_markup"]["inline_keyboard"] != []

      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 42}})
    end)

    markup = %{inline_keyboard: [[%{text: "Send", callback_data: "cb"}]]}

    assert {:ok, %{"message_id" => 42}} =
             Api.send_message("fake", 1, "hello", reply_markup: markup)
  end

  test "get_updates/3 passes offset" do
    Req.Test.expect(:telegram_api, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      parsed = Jason.decode!(body)
      assert parsed["offset"] == 9

      Req.Test.json(conn, %{"ok" => true, "result" => [%{"update_id" => 9}]})
    end)

    assert {:ok, [%{"update_id" => 9}]} = Api.get_updates("fake", 9, 1)
  end
end
