defmodule SymphonyV2Web.SettingsLiveTest do
  use SymphonyV2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyV2.Settings

  setup :register_and_log_in_user

  describe "settings page" do
    test "renders page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      assert html =~ "Application Settings"
    end

    test "displays current config values", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      assert html =~ "mix test"
      assert html =~ "claude_code"
      assert html =~ "gemini_cli"
      assert html =~ "10 min"
    end

    test "displays repo path status", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      # Repo path is nil or invalid in test env
      assert html =~ "Repo Path"
    end

    test "displays skip permissions status", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      assert html =~ "disabled"
    end
  end

  describe "agent registry table" do
    test "shows built-in agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      assert has_element?(view, "#agent-claude_code")
      assert has_element?(view, "#agent-codex")
      assert has_element?(view, "#agent-gemini_cli")
      assert has_element?(view, "#agent-opencode")
    end

    test "shows agent details", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      assert html =~ "claude"
      assert html =~ "codex"
      assert html =~ "gemini"
      assert html =~ "opencode"
      assert html =~ "ANTHROPIC_API_KEY"
      assert html =~ "OPENAI_API_KEY"
    end

    test "shows installed status", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      # At least some status badges should be present
      assert html =~ "installed" or html =~ "not found"
    end

    test "shows source labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      assert html =~ "built-in"
    end
  end

  describe "settings editing" do
    test "shows edit form on click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Edit") |> render_click()

      assert has_element?(view, "form")
      assert has_element?(view, "input[name=\"app_setting[test_command]\"]")
    end

    test "cancel hides edit form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Edit") |> render_click()
      assert has_element?(view, "form")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "input[name=\"app_setting[test_command]\"]")
    end

    test "validates settings on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("form", app_setting: %{agent_timeout_ms: 0})
      |> render_change()

      assert render(view) =~ "must be greater than 0"
    end

    test "saves valid settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("form", app_setting: %{test_command: "make test", max_retries: 3})
      |> render_submit()

      # Form should be hidden after save
      refute has_element?(view, "input[name=\"app_setting[test_command]\"]")

      # Values should be updated
      html = render(view)
      assert html =~ "make test"
    end

    test "persists settings to database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("form", app_setting: %{test_command: "pytest", max_retries: 4})
      |> render_submit()

      setting = Settings.get_settings()
      assert setting.test_command == "pytest"
      assert setting.max_retries == 4
    end
  end

  describe "custom agent management" do
    test "shows add agent form on click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Add Agent") |> render_click()

      assert has_element?(view, "input[name=\"custom_agent[name]\"]")
      assert has_element?(view, "input[name=\"custom_agent[command]\"]")
    end

    test "cancel hides add agent form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Add Agent") |> render_click()
      assert has_element?(view, "input[name=\"custom_agent[name]\"]")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "input[name=\"custom_agent[name]\"]")
    end

    test "creates a custom agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Add Agent") |> render_click()

      view
      |> form("form",
        custom_agent: %{name: "my_agent", command: "my-cli", prompt_flag: "-p"}
      )
      |> render_submit()

      # Form should be hidden
      refute has_element?(view, "input[name=\"custom_agent[name]\"]")

      # Agent should appear in table
      html = render(view)
      assert html =~ "my_agent"
      assert html =~ "my-cli"
      assert html =~ "custom"
    end

    test "validates agent on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view |> element("button", "Add Agent") |> render_click()

      view
      |> form("form", custom_agent: %{name: "Invalid-Name", command: "", prompt_flag: ""})
      |> render_change()

      html = render(view)
      assert html =~ "must be lowercase with underscores"
    end

    test "shows delete button for custom agents", %{conn: conn} do
      {:ok, _} =
        Settings.create_custom_agent(%{
          "name" => "deletable",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      {:ok, view, _html} = live(conn, ~p"/app-settings")

      assert has_element?(view, "#agent-deletable")
      assert has_element?(view, "button[phx-click=\"delete_agent\"]")
    end

    test "deletes a custom agent", %{conn: conn} do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "to_delete",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      {:ok, view, _html} = live(conn, ~p"/app-settings")
      assert has_element?(view, "#agent-to_delete")

      view
      |> element(~s(button[phx-click="delete_agent"][phx-value-id="#{agent.id}"]))
      |> render_click()

      refute has_element?(view, "#agent-to_delete")
    end

    test "shows edit button for custom agents", %{conn: conn} do
      {:ok, _} =
        Settings.create_custom_agent(%{
          "name" => "editable",
          "command" => "cmd",
          "prompt_flag" => "-p"
        })

      {:ok, view, _html} = live(conn, ~p"/app-settings")
      assert has_element?(view, "button[phx-click=\"edit_agent\"]")
    end

    test "edits a custom agent", %{conn: conn} do
      {:ok, agent} =
        Settings.create_custom_agent(%{
          "name" => "edit_me",
          "command" => "old_cmd",
          "prompt_flag" => "-p"
        })

      {:ok, view, _html} = live(conn, ~p"/app-settings")

      view
      |> element(~s(button[phx-click="edit_agent"][phx-value-id="#{agent.id}"]))
      |> render_click()

      assert has_element?(view, "input[name=\"custom_agent[command]\"]")

      view
      |> form("form", custom_agent: %{command: "new_cmd"})
      |> render_submit()

      html = render(view)
      assert html =~ "new_cmd"
    end
  end

  describe "navigation" do
    test "app settings link in nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app-settings")

      assert html =~ "App Settings"
    end
  end
end
