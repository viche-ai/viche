defmodule VicheWeb.HealthControllerTest do
  use VicheWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 with ok status", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert response(conn, 200) == "ok"
    end
  end
end
