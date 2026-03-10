defmodule SymphonyV2.Plans.PlanParserTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Plans.PlanParser

  describe "parse/1" do
    test "parses a valid plan.json file" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "Create schema",
              "spec" => "Create the Ecto schema for users",
              "agent_type" => "claude_code"
            },
            %{
              "position" => 2,
              "title" => "Add tests",
              "spec" => "Write unit tests for the schema",
              "agent_type" => "codex"
            }
          ]
        })

      assert {:ok, tasks} = PlanParser.parse(path)
      assert length(tasks) == 2

      assert Enum.at(tasks, 0) == %{
               position: 1,
               title: "Create schema",
               spec: "Create the Ecto schema for users",
               agent_type: "claude_code"
             }

      assert Enum.at(tasks, 1) == %{
               position: 2,
               title: "Add tests",
               spec: "Write unit tests for the schema",
               agent_type: "codex"
             }
    end

    test "returns error for non-existent file" do
      assert {:error, {:file_not_found, _}} = PlanParser.parse("/nonexistent/plan.json")
    end

    test "returns error for invalid JSON" do
      path = write_raw_file("not json {{{")
      assert {:error, :invalid_json} = PlanParser.parse(path)
    end

    test "returns error for missing tasks key" do
      path = write_plan_file(%{"subtasks" => []})
      assert {:error, :missing_tasks_key} = PlanParser.parse(path)
    end

    test "returns error for empty tasks array" do
      path = write_plan_file(%{"tasks" => []})
      assert {:error, :empty_tasks} = PlanParser.parse(path)
    end

    test "returns error for tasks not being a list" do
      path = write_plan_file(%{"tasks" => "not a list"})
      assert {:error, :tasks_not_a_list} = PlanParser.parse(path)
    end

    test "returns error for missing required fields" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{"position" => 1}
          ]
        })

      assert {:error, {:invalid_tasks, errors}} = PlanParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "title"))
      assert Enum.any?(errors, &String.contains?(&1, "spec"))
      assert Enum.any?(errors, &String.contains?(&1, "agent_type"))
    end

    test "returns error for empty title" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "",
              "spec" => "Do something",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_tasks, errors}} = PlanParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "title"))
    end

    test "returns error for empty spec" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "Do thing",
              "spec" => "   ",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_tasks, errors}} = PlanParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "spec"))
    end

    test "returns error for non-sequential positions" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "First",
              "spec" => "Do first thing",
              "agent_type" => "claude_code"
            },
            %{
              "position" => 3,
              "title" => "Third",
              "spec" => "Do third thing",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_positions, [1, 3], [1, 2]}} = PlanParser.parse(path)
    end

    test "returns error for duplicate positions" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "First",
              "spec" => "Do first thing",
              "agent_type" => "claude_code"
            },
            %{
              "position" => 1,
              "title" => "Also first",
              "spec" => "Do another first thing",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_positions, _, _}} = PlanParser.parse(path)
    end

    test "returns error for positions not starting from 1" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 2,
              "title" => "Second",
              "spec" => "Do second thing",
              "agent_type" => "claude_code"
            },
            %{
              "position" => 3,
              "title" => "Third",
              "spec" => "Do third thing",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_positions, _, _}} = PlanParser.parse(path)
    end

    test "returns error for unknown agent types" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "Do thing",
              "spec" => "Do the thing",
              "agent_type" => "unknown_agent"
            }
          ]
        })

      assert {:error, {:unknown_agent_types, ["unknown_agent"]}} = PlanParser.parse(path)
    end

    test "returns error for negative position" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => -1,
              "title" => "Bad position",
              "spec" => "Do something",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_tasks, errors}} = PlanParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "position"))
    end

    test "returns error for non-integer position" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => "one",
              "title" => "Bad position",
              "spec" => "Do something",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:error, {:invalid_tasks, errors}} = PlanParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "position"))
    end

    test "returns error for task entry that is not a map" do
      path =
        write_plan_file(%{
          "tasks" => ["not a map"]
        })

      assert {:error, {:invalid_tasks, errors}} = PlanParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "must be a map"))
    end

    test "sorts tasks by position in output" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 2,
              "title" => "Second",
              "spec" => "Second task",
              "agent_type" => "codex"
            },
            %{
              "position" => 1,
              "title" => "First",
              "spec" => "First task",
              "agent_type" => "claude_code"
            }
          ]
        })

      assert {:ok, tasks} = PlanParser.parse(path)
      assert Enum.at(tasks, 0).position == 1
      assert Enum.at(tasks, 0).title == "First"
      assert Enum.at(tasks, 1).position == 2
      assert Enum.at(tasks, 1).title == "Second"
    end

    test "accepts all valid agent types" do
      path =
        write_plan_file(%{
          "tasks" => [
            %{
              "position" => 1,
              "title" => "Claude task",
              "spec" => "Use claude",
              "agent_type" => "claude_code"
            },
            %{
              "position" => 2,
              "title" => "Codex task",
              "spec" => "Use codex",
              "agent_type" => "codex"
            },
            %{
              "position" => 3,
              "title" => "Gemini task",
              "spec" => "Use gemini",
              "agent_type" => "gemini_cli"
            },
            %{
              "position" => 4,
              "title" => "Opencode task",
              "spec" => "Use opencode",
              "agent_type" => "opencode"
            }
          ]
        })

      assert {:ok, tasks} = PlanParser.parse(path)
      assert length(tasks) == 4
    end
  end

  describe "parse_map/1" do
    test "parses a valid plan map" do
      data = %{
        "tasks" => [
          %{
            "position" => 1,
            "title" => "First task",
            "spec" => "Do the first thing",
            "agent_type" => "claude_code"
          }
        ]
      }

      assert {:ok, [task]} = PlanParser.parse_map(data)
      assert task.position == 1
      assert task.title == "First task"
    end

    test "returns error for invalid map" do
      assert {:error, :missing_tasks_key} = PlanParser.parse_map(%{})
    end
  end

  # --- Helpers ---

  defp write_plan_file(data) do
    path = temp_file_path("plan.json")
    File.write!(path, Jason.encode!(data))
    path
  end

  defp write_raw_file(content) do
    path = temp_file_path("plan.json")
    File.write!(path, content)
    path
  end

  defp temp_file_path(filename) do
    dir = Path.join(System.tmp_dir!(), "plan_parser_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, filename)
  end
end
