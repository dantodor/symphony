defmodule SymphonyV2Web.UserRegistrationControllerTest do
  use SymphonyV2Web.ConnCase, async: true

  import SymphonyV2.AccountsFixtures

  describe "GET /users/register" do
    test "renders registration page", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ ~p"/users/log-in"
      assert response =~ ~p"/users/register"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/users/register")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /users/register" do
    test "creates account and logs in", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => valid_user_attributes(email: email)
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "render errors for invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => "with spaces", "password" => "short"}
        })

      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ "must have the @ sign and no spaces"
    end
  end
end
