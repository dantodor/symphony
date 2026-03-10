defmodule SymphonyV2.Agents.ReviewParserTest do
  use ExUnit.Case, async: true

  alias SymphonyV2.Agents.ReviewParser

  defp write_review_file(data) do
    path = temp_file_path("review")
    File.write!(path, Jason.encode!(data))
    path
  end

  defp write_raw_file(content) do
    path = temp_file_path("review_raw")
    File.write!(path, content)
    path
  end

  defp temp_file_path(prefix) do
    dir = System.tmp_dir!()
    Path.join(dir, "#{prefix}_#{System.unique_integer([:positive])}.json")
  end

  describe "parse/1 — valid reviews" do
    test "parses approved review with issues" do
      path =
        write_review_file(%{
          "verdict" => "approved",
          "reasoning" => "The implementation correctly handles all cases.",
          "issues" => [
            %{"severity" => "nit", "description" => "Could use a better variable name"}
          ]
        })

      assert {:ok, review} = ReviewParser.parse(path)
      assert review.verdict == "approved"
      assert review.reasoning == "The implementation correctly handles all cases."
      assert length(review.issues) == 1
      assert hd(review.issues).severity == "nit"
      assert hd(review.issues).description == "Could use a better variable name"
    end

    test "parses rejected review with multiple issues" do
      path =
        write_review_file(%{
          "verdict" => "rejected",
          "reasoning" => "Several critical problems found.",
          "issues" => [
            %{"severity" => "critical", "description" => "Tests use hardcoded values"},
            %{"severity" => "major", "description" => "Missing error handling"}
          ]
        })

      assert {:ok, review} = ReviewParser.parse(path)
      assert review.verdict == "rejected"
      assert length(review.issues) == 2
    end

    test "parses review without issues field" do
      path =
        write_review_file(%{
          "verdict" => "approved",
          "reasoning" => "Everything looks good."
        })

      assert {:ok, review} = ReviewParser.parse(path)
      assert review.verdict == "approved"
      assert review.issues == []
    end

    test "parses review with empty issues list" do
      path =
        write_review_file(%{
          "verdict" => "approved",
          "reasoning" => "Clean implementation.",
          "issues" => []
        })

      assert {:ok, review} = ReviewParser.parse(path)
      assert review.issues == []
    end

    test "accepts all valid severity levels" do
      for severity <- ~w(critical major minor nit) do
        path =
          write_review_file(%{
            "verdict" => "rejected",
            "reasoning" => "Issues found.",
            "issues" => [
              %{"severity" => severity, "description" => "Some issue"}
            ]
          })

        assert {:ok, review} = ReviewParser.parse(path)
        assert hd(review.issues).severity == severity
      end
    end
  end

  describe "parse/1 — file errors" do
    test "returns error for non-existent file" do
      assert {:error, {:file_not_found, _}} = ReviewParser.parse("/nonexistent/review.json")
    end

    test "returns error for invalid JSON" do
      path = write_raw_file("not json at all {{{")
      assert {:error, :invalid_json} = ReviewParser.parse(path)
    end
  end

  describe "parse/1 — verdict validation" do
    test "returns error for missing verdict" do
      path =
        write_review_file(%{
          "reasoning" => "Some reasoning."
        })

      assert {:error, :missing_verdict} = ReviewParser.parse(path)
    end

    test "returns error for invalid verdict value" do
      path =
        write_review_file(%{
          "verdict" => "maybe",
          "reasoning" => "Not sure."
        })

      assert {:error, {:invalid_verdict, "maybe"}} = ReviewParser.parse(path)
    end

    test "returns error for non-string verdict" do
      path =
        write_review_file(%{
          "verdict" => 42,
          "reasoning" => "Some reasoning."
        })

      assert {:error, :verdict_must_be_string} = ReviewParser.parse(path)
    end
  end

  describe "parse/1 — reasoning validation" do
    test "returns error for missing reasoning" do
      path =
        write_review_file(%{
          "verdict" => "approved"
        })

      assert {:error, :missing_reasoning} = ReviewParser.parse(path)
    end

    test "returns error for empty reasoning" do
      path =
        write_review_file(%{
          "verdict" => "approved",
          "reasoning" => "   "
        })

      assert {:error, :empty_reasoning} = ReviewParser.parse(path)
    end

    test "returns error for non-string reasoning" do
      path =
        write_review_file(%{
          "verdict" => "approved",
          "reasoning" => 123
        })

      assert {:error, :reasoning_must_be_string} = ReviewParser.parse(path)
    end
  end

  describe "parse/1 — issues validation" do
    test "returns error for non-list issues" do
      path =
        write_review_file(%{
          "verdict" => "approved",
          "reasoning" => "Fine.",
          "issues" => "not a list"
        })

      assert {:error, :issues_must_be_list} = ReviewParser.parse(path)
    end

    test "returns error for issue missing severity" do
      path =
        write_review_file(%{
          "verdict" => "rejected",
          "reasoning" => "Problems.",
          "issues" => [
            %{"description" => "Missing something"}
          ]
        })

      assert {:error, {:invalid_issues, errors}} = ReviewParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "severity"))
    end

    test "returns error for issue missing description" do
      path =
        write_review_file(%{
          "verdict" => "rejected",
          "reasoning" => "Problems.",
          "issues" => [
            %{"severity" => "critical"}
          ]
        })

      assert {:error, {:invalid_issues, errors}} = ReviewParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "description"))
    end

    test "returns error for invalid severity value" do
      path =
        write_review_file(%{
          "verdict" => "rejected",
          "reasoning" => "Problems.",
          "issues" => [
            %{"severity" => "blocker", "description" => "Something"}
          ]
        })

      assert {:error, {:invalid_issues, errors}} = ReviewParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "severity must be one of"))
    end

    test "returns error for non-map issue entry" do
      path =
        write_review_file(%{
          "verdict" => "rejected",
          "reasoning" => "Problems.",
          "issues" => ["just a string"]
        })

      assert {:error, {:invalid_issues, errors}} = ReviewParser.parse(path)
      assert Enum.any?(errors, &String.contains?(&1, "must be a map"))
    end
  end

  describe "parse/1 — format errors" do
    test "returns error for non-map review" do
      path = write_raw_file(Jason.encode!([1, 2, 3]))
      assert {:error, :invalid_review_format} = ReviewParser.parse(path)
    end
  end

  describe "parse_map/1" do
    test "parses valid review from map" do
      data = %{
        "verdict" => "approved",
        "reasoning" => "Looks good."
      }

      assert {:ok, review} = ReviewParser.parse_map(data)
      assert review.verdict == "approved"
    end

    test "returns error for invalid map" do
      assert {:error, :missing_verdict} = ReviewParser.parse_map(%{"reasoning" => "test"})
    end
  end
end
