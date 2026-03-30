defmodule VicheWeb.Live.RegistryScopeTest do
  use ExUnit.Case, async: true

  alias VicheWeb.Live.RegistryScope

  describe "registries_for_agent/2" do
    test "returns the registries list when agent_id is found" do
      map = %{"abc-123" => ["global", "team-x"]}
      assert RegistryScope.registries_for_agent(map, "abc-123") == ["global", "team-x"]
    end

    test "returns empty list when agent_id is not in the map" do
      map = %{"abc-123" => ["global"]}
      assert RegistryScope.registries_for_agent(map, "unknown-id") == []
    end

    test "returns empty list for empty map" do
      assert RegistryScope.registries_for_agent(%{}, "any-id") == []
    end

    test "returns single-element list for single-registry agent" do
      map = %{"agent-1" => ["team-only"]}
      assert RegistryScope.registries_for_agent(map, "agent-1") == ["team-only"]
    end
  end

  describe "push_event_by_registry/3" do
    defp make_event(id, seconds_ago \\ 0) do
      %{
        id: id,
        inserted_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      }
    end

    test "pushes event into the correct registry bucket" do
      event = make_event("event-1")
      result = RegistryScope.push_event_by_registry(%{}, ["global"], event)
      assert result == %{"global" => [event]}
    end

    test "pushes event into multiple registry buckets at once" do
      event = make_event("event-1")
      result = RegistryScope.push_event_by_registry(%{}, ["global", "team-x"], event)
      assert result == %{"global" => [event], "team-x" => [event]}
    end

    test "prepends to existing bucket (newest first)" do
      old_event = make_event("event-old")
      new_event = make_event("event-new")

      feed = %{"global" => [old_event]}
      result = RegistryScope.push_event_by_registry(feed, ["global"], new_event)

      assert result == %{"global" => [new_event, old_event]}
    end

    test "caps bucket at the specified limit (default 50)" do
      existing = Enum.map(1..50, &make_event("existing-#{&1}"))
      feed = %{"global" => existing}
      new_event = make_event("new-event")

      result = RegistryScope.push_event_by_registry(feed, ["global"], new_event)
      bucket = result["global"]

      assert length(bucket) == 50
      assert hd(bucket) == new_event
      # The oldest event is dropped
      refute List.last(existing) in bucket
    end

    test "caps bucket at a custom limit" do
      existing = Enum.map(1..5, &make_event("e-#{&1}"))
      feed = %{"global" => existing}
      new_event = make_event("new")

      result = RegistryScope.push_event_by_registry(feed, ["global"], new_event, 3)
      bucket = result["global"]

      assert length(bucket) == 3
      assert hd(bucket) == new_event
    end

    test "creates new bucket when registry not yet in map" do
      event = make_event("e1")
      result = RegistryScope.push_event_by_registry(%{"other" => []}, ["new-registry"], event)
      assert result["new-registry"] == [event]
      # other registry untouched
      assert result["other"] == []
    end

    test "does not push to buckets not in the registries list" do
      event = make_event("e1")
      feed = %{"global" => [], "team-x" => []}
      result = RegistryScope.push_event_by_registry(feed, ["global"], event)
      assert result["global"] == [event]
      assert result["team-x"] == []
    end
  end

  describe "selected_feed/2" do
    defp make_event_at(id, dt) do
      %{id: id, inserted_at: dt}
    end

    test "returns the feed for the given registry" do
      event = make_event_at("e1", DateTime.utc_now())
      feed = %{"global" => [event], "team-x" => []}
      assert RegistryScope.selected_feed(feed, "global") == [event]
    end

    test "returns empty list when registry not in map" do
      assert RegistryScope.selected_feed(%{}, "missing") == []
    end

    test "returns empty list for registry with empty bucket" do
      feed = %{"global" => []}
      assert RegistryScope.selected_feed(feed, "global") == []
    end

    test "'all' merges all registry buckets into one flat list" do
      e1 = make_event_at("e1", ~U[2026-01-01 10:00:00Z])
      e2 = make_event_at("e2", ~U[2026-01-01 11:00:00Z])
      e3 = make_event_at("e3", ~U[2026-01-01 09:00:00Z])

      feed = %{
        "global" => [e2, e1],
        "team-x" => [e3]
      }

      result = RegistryScope.selected_feed(feed, "all")
      assert length(result) == 3
      assert e1 in result
      assert e2 in result
      assert e3 in result
    end

    test "'all' deduplicates events that appear in multiple registry buckets" do
      shared_event = make_event_at("shared", ~U[2026-01-01 10:00:00Z])
      unique_event = make_event_at("unique", ~U[2026-01-01 11:00:00Z])

      feed = %{
        "global" => [shared_event, unique_event],
        "team-x" => [shared_event]
      }

      result = RegistryScope.selected_feed(feed, "all")
      # shared appears once despite being in both buckets
      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert "shared" in ids
      assert "unique" in ids
    end

    test "'all' sorts events by inserted_at descending (newest first)" do
      e_old = make_event_at("old", ~U[2026-01-01 08:00:00Z])
      e_mid = make_event_at("mid", ~U[2026-01-01 10:00:00Z])
      e_new = make_event_at("new", ~U[2026-01-01 12:00:00Z])

      feed = %{
        "global" => [e_old, e_new],
        "team-x" => [e_mid]
      }

      result = RegistryScope.selected_feed(feed, "all")
      ids = Enum.map(result, & &1.id)
      assert ids == ["new", "mid", "old"]
    end

    test "'all' returns empty list when all buckets are empty" do
      feed = %{"global" => [], "team-x" => []}
      assert RegistryScope.selected_feed(feed, "all") == []
    end

    test "'all' returns empty list for empty map" do
      assert RegistryScope.selected_feed(%{}, "all") == []
    end

    test "'all' keeps the NEWEST event when same id appears with different timestamps in different buckets" do
      old_version = make_event_at("dup-id", ~U[2026-01-01 08:00:00Z])
      new_version = make_event_at("dup-id", ~U[2026-01-01 12:00:00Z])

      feed = %{
        "global" => [old_version],
        "team-x" => [new_version]
      }

      result = RegistryScope.selected_feed(feed, "all")
      assert length(result) == 1
      [kept] = result
      assert kept.inserted_at == ~U[2026-01-01 12:00:00Z]
    end
  end

  describe "push_event_by_registry/3 — duplicate registry names" do
    test "duplicate registry names in list do not double-insert" do
      event = %{id: "e1", inserted_at: DateTime.utc_now()}
      result = RegistryScope.push_event_by_registry(%{}, ["global", "global"], event)
      assert length(result["global"]) == 1
    end
  end
end
