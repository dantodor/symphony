defmodule SymphonyV2Web.PageControllerTest do
  use SymphonyV2Web.ConnCase

  import SymphonyV2.AccountsFixtures

  test "GET / requires authentication", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / renders when authenticated", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
