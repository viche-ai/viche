defmodule Viche.MessageCounter do
  @moduledoc """
  Simple GenServer that tracks messages sent today (since server start).
  Broadcasts increments to the "metrics:messages" PubSub topic so all
  LiveViews can subscribe and stay in sync.
  """
  use GenServer

  @topic "metrics:messages"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  end

  @spec increment() :: :ok
  def increment do
    GenServer.cast(__MODULE__, :increment)
  end

  @spec get() :: non_neg_integer()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @impl true
  def init(count) do
    {:ok, count}
  end

  @impl true
  def handle_cast(:increment, count) do
    new_count = count + 1
    Phoenix.PubSub.broadcast(Viche.PubSub, @topic, {:messages_today, new_count})
    {:noreply, new_count}
  end

  @impl true
  def handle_call(:get, _from, count) do
    {:reply, count, count}
  end
end
