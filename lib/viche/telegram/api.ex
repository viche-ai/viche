defmodule Viche.Telegram.Api do
  @moduledoc """
  Thin wrapper around the Telegram Bot API using `Req`.
  """

  @base_url "https://api.telegram.org"

  @spec get_me(String.t()) :: {:ok, map()} | {:error, term()}
  def get_me(bot_token) do
    post(bot_token, "getMe", %{})
  end

  @spec send_message(String.t(), integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(bot_token, chat_id, text, opts \\ []) do
    body =
      %{chat_id: chat_id, text: text, parse_mode: Keyword.get(opts, :parse_mode, "HTML")}
      |> maybe_put(:reply_markup, Keyword.get(opts, :reply_markup))
      |> maybe_put(:reply_to_message_id, Keyword.get(opts, :reply_to_message_id))

    post(bot_token, "sendMessage", body)
  end

  @spec get_updates(String.t(), integer() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_updates(bot_token, offset \\ nil, timeout \\ 30) do
    body =
      %{timeout: timeout, allowed_updates: ["message", "callback_query"]}
      |> maybe_put(:offset, offset)

    case post(bot_token, "getUpdates", body, receive_timeout: (timeout + 5) * 1_000) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      error -> error
    end
  end

  @spec answer_callback_query(String.t(), String.t(), keyword()) :: {:ok, true} | {:error, term()}
  def answer_callback_query(bot_token, callback_query_id, opts \\ []) do
    body =
      %{callback_query_id: callback_query_id}
      |> maybe_put(:text, Keyword.get(opts, :text))

    post(bot_token, "answerCallbackQuery", body)
  end

  @spec post(String.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  defp post(bot_token, method, body, req_opts \\ []) do
    url = "#{@base_url}/bot#{bot_token}/#{method}"

    opts =
      [json: body, retry: false]
      |> Keyword.merge(Application.get_env(:viche, :telegram_req_options, []))
      |> Keyword.merge(req_opts)

    case Req.post(url, opts) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{body: %{"ok" => false, "description" => desc}}} ->
        {:error, {:telegram, desc}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
