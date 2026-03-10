defmodule SymphonyV2.Agents.ReviewParser do
  @moduledoc """
  Parses and validates review.json files produced by the review agent.

  The review agent writes a `review.json` to the workspace root containing
  a verdict (approved/rejected), reasoning, and optionally a list of issues.
  This module reads, decodes, and validates the structure.
  """

  @type issue :: %{
          severity: String.t(),
          description: String.t()
        }

  @type review :: %{
          verdict: String.t(),
          reasoning: String.t(),
          issues: [issue()]
        }

  @valid_verdicts ~w(approved rejected)
  @valid_severities ~w(critical major minor nit)

  @doc """
  Parses a review.json file at the given path.

  Reads the file, decodes JSON, and validates the structure.
  Returns `{:ok, review}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, review()} | {:error, term()}
  def parse(file_path) do
    with {:ok, content} <- read_file(file_path),
         {:ok, decoded} <- decode_json(content),
         {:ok, review} <- validate_review(decoded) do
      {:ok, review}
    end
  end

  @doc """
  Parses a review from a raw map (already decoded JSON).

  Useful when the review data is already in memory (e.g., from tests).
  Returns `{:ok, review}` or `{:error, reason}`.
  """
  @spec parse_map(map()) :: {:ok, review()} | {:error, term()}
  def parse_map(data) when is_map(data) do
    validate_review(data)
  end

  # --- Private ---

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, {:file_not_found, path}}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp validate_review(data) when is_map(data) do
    with :ok <- validate_verdict(data),
         :ok <- validate_reasoning(data),
         :ok <- validate_issues(data) do
      {:ok, normalize_review(data)}
    end
  end

  defp validate_review(_), do: {:error, :invalid_review_format}

  defp validate_verdict(%{"verdict" => verdict}) when verdict in @valid_verdicts, do: :ok

  defp validate_verdict(%{"verdict" => verdict}) when is_binary(verdict) do
    {:error, {:invalid_verdict, verdict}}
  end

  defp validate_verdict(%{"verdict" => _}), do: {:error, :verdict_must_be_string}
  defp validate_verdict(_), do: {:error, :missing_verdict}

  defp validate_reasoning(%{"reasoning" => reasoning}) when is_binary(reasoning) do
    if String.trim(reasoning) == "" do
      {:error, :empty_reasoning}
    else
      :ok
    end
  end

  defp validate_reasoning(%{"reasoning" => _}), do: {:error, :reasoning_must_be_string}
  defp validate_reasoning(_), do: {:error, :missing_reasoning}

  defp validate_issues(%{"issues" => issues}) when is_list(issues) do
    errors =
      issues
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {issue, index} -> validate_single_issue(issue, index) end)

    case errors do
      [] -> :ok
      errors -> {:error, {:invalid_issues, errors}}
    end
  end

  # Issues are optional — no "issues" key is fine
  defp validate_issues(%{"issues" => _}), do: {:error, :issues_must_be_list}
  defp validate_issues(_), do: :ok

  defp validate_single_issue(issue, index) when is_map(issue) do
    []
    |> maybe_add_error(
      !non_empty_string?(issue["severity"]),
      "issue #{index}: severity must be a non-empty string"
    )
    |> maybe_add_error(
      non_empty_string?(issue["severity"]) && issue["severity"] not in @valid_severities,
      "issue #{index}: severity must be one of: #{Enum.join(@valid_severities, ", ")}"
    )
    |> maybe_add_error(
      !non_empty_string?(issue["description"]),
      "issue #{index}: description must be a non-empty string"
    )
  end

  defp validate_single_issue(_issue, index) do
    ["issue #{index}: must be a map/object"]
  end

  defp normalize_review(data) do
    issues =
      (data["issues"] || [])
      |> Enum.map(fn issue ->
        %{
          severity: issue["severity"],
          description: issue["description"]
        }
      end)

    %{
      verdict: data["verdict"],
      reasoning: data["reasoning"],
      issues: issues
    }
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_), do: false

  defp maybe_add_error(errors, true, message), do: [message | errors]
  defp maybe_add_error(errors, false, _message), do: errors
end
