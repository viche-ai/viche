defmodule VicheWeb.Live.RegistryScope do
  @moduledoc """
  Shared helpers for registry-scoped LiveView state and PubSub management.

  Provides normalized subscription switching so every registry-aware LiveView
  shares the same semantics for:
    - Translating a registry string from UI params to domain-layer arguments
    - Subscribing / unsubscribing from Phoenix PubSub registry topics
    - Switching from one registry to another (no-op when registry is unchanged)
  """

  @doc """
  Converts a UI-facing registry string to the domain-layer argument expected by
  `Viche.Agents.list_agents_with_status/1`.

  The special value `"all"` maps to the `:all` atom; everything else is passed through.
  """
  @spec to_filter(String.t()) :: String.t() | :all
  def to_filter("all"), do: :all
  def to_filter(registry), do: registry

  @doc """
  Validates that a registry string from URL params is in the allowed set.

  Returns `registry` unchanged when it is `"global"`, `"all"`, or one of the
  caller-supplied `registries` list.  Falls back to `"global"` otherwise,
  preventing unknown registry names from propagating into LiveView state.
  """
  @spec normalize(String.t(), [String.t()]) :: String.t()
  def normalize(registry, registries) do
    if registry in (["global", "all"] ++ registries), do: registry, else: "global"
  end

  @doc """
  Switches PubSub subscriptions from `old_registry` to `new_registry`.

  No-op when both values are identical.
  """
  @spec switch(String.t(), String.t()) :: :ok
  def switch(same, same), do: :ok

  def switch(old, new) do
    unsubscribe(old)
    subscribe(new)
  end

  @doc """
  Subscribes to PubSub topic(s) for the given registry.

  When `registry` is `"all"`, subscribes to every currently known registry topic.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe("all") do
    Enum.each(Viche.Agents.list_registries(), fn r ->
      Phoenix.PubSub.subscribe(Viche.PubSub, "registry:#{r}")
    end)
  end

  def subscribe(registry) when is_binary(registry) do
    Phoenix.PubSub.subscribe(Viche.PubSub, "registry:#{registry}")
    :ok
  end

  @doc """
  Unsubscribes from PubSub topic(s) for the given registry.

  When `registry` is `"all"`, unsubscribes from every currently known registry topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe("all") do
    Enum.each(Viche.Agents.list_registries(), fn r ->
      Phoenix.PubSub.unsubscribe(Viche.PubSub, "registry:#{r}")
    end)
  end

  def unsubscribe(registry) when is_binary(registry) do
    Phoenix.PubSub.unsubscribe(Viche.PubSub, "registry:#{registry}")
    :ok
  end

  @doc "Look up registries for an agent from the preloaded map."
  @spec registries_for_agent(%{String.t() => [String.t()]}, String.t()) :: [String.t()]
  def registries_for_agent(agent_registry_map, agent_id) do
    Map.get(agent_registry_map, agent_id, [])
  end

  @doc "Push an event into per-registry feed buffers for each of the given registries."
  @spec push_event_by_registry(%{String.t() => [map()]}, [String.t()], map(), pos_integer()) ::
          %{String.t() => [map()]}
  def push_event_by_registry(feed_by_registry, registries, event, cap \\ 50) do
    registries
    |> Enum.uniq()
    |> Enum.reduce(feed_by_registry, fn registry, acc ->
      Map.update(acc, registry, [event], fn feed -> [event | Enum.take(feed, cap - 1)] end)
    end)
  end

  @doc "Get the feed for the selected registry. For 'all', merge and sort by inserted_at descending."
  @spec selected_feed(%{String.t() => [map()]}, String.t()) :: [map()]
  def selected_feed(feed_by_registry, "all") do
    feed_by_registry
    |> Enum.flat_map(fn {_registry, events} -> events end)
    |> Enum.reduce(%{}, fn event, acc ->
      Map.update(acc, event.id, event, &keep_newer(event, &1))
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  def selected_feed(feed_by_registry, registry) do
    Map.get(feed_by_registry, registry, [])
  end

  @spec keep_newer(map(), map()) :: map()
  defp keep_newer(a, b) do
    if DateTime.compare(a.inserted_at, b.inserted_at) == :gt, do: a, else: b
  end
end
