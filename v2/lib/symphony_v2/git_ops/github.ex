defmodule SymphonyV2.GitOps.GitHub do
  @moduledoc """
  GitHub CLI (`gh`) operations for PR creation and merging.

  These functions require the `gh` CLI to be installed and authenticated.
  They are separated from GitOps because they can only be integration-tested
  against a real GitHub repository.
  """

  require Logger

  @spec create_pr(String.t(), map()) ::
          {:ok, %{url: String.t(), number: integer()}} | {:error, term()}
  def create_pr(workspace, opts) do
    args =
      ["pr", "create"] ++
        build_pr_args(opts)

    case System.cmd("gh", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        url = String.trim(output)

        case url |> String.split("/") |> List.last() |> Integer.parse() do
          {number, _} ->
            Logger.info("Created PR url=#{url} number=#{number}")
            {:ok, %{url: url, number: number}}

          :error ->
            Logger.error("Could not parse PR number from gh output", output: url)
            {:error, {:pr_parse_failed, url}}
        end

      {output, exit_code} ->
        Logger.error("Failed to create PR exit_code=#{exit_code} output=#{String.trim(output)}")

        {:error, {:pr_create_failed, exit_code, String.trim(output)}}
    end
  end

  @spec merge_pr(String.t(), integer()) :: :ok | {:error, term()}
  def merge_pr(workspace, pr_number) do
    args = ["pr", "merge", to_string(pr_number), "--merge"]

    case System.cmd("gh", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("Merged PR number=#{pr_number}")
        :ok

      {output, exit_code} ->
        Logger.error(
          "Failed to merge PR number=#{pr_number} exit_code=#{exit_code} output=#{String.trim(output)}"
        )

        {:error, {:merge_failed, exit_code, String.trim(output)}}
    end
  end

  @spec merge_stack(String.t(), [integer()]) ::
          {:ok, [integer()]} | {:error, {:merge_failed_at, integer(), term()}}
  def merge_stack(workspace, pr_numbers) when is_list(pr_numbers) do
    merge_stack_loop(workspace, pr_numbers, [])
  end

  defp merge_stack_loop(_workspace, [], merged), do: {:ok, Enum.reverse(merged)}

  defp merge_stack_loop(workspace, [pr_number | rest], merged) do
    case merge_pr(workspace, pr_number) do
      :ok ->
        merge_stack_loop(workspace, rest, [pr_number | merged])

      {:error, reason} ->
        {:error, {:merge_failed_at, pr_number, reason}}
    end
  end

  defp build_pr_args(opts) do
    []
    |> maybe_add("--repo", opts[:repo])
    |> maybe_add("--head", opts[:head])
    |> maybe_add("--base", opts[:base])
    |> maybe_add("--title", opts[:title])
    |> maybe_add("--body", opts[:body])
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, value]
end
