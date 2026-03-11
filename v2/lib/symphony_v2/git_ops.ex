defmodule SymphonyV2.GitOps do
  @moduledoc """
  Git operations as pure functions taking workspace path.

  All git commands are executed via `System.cmd` with `-C <workspace>` to avoid
  changing the current working directory. Symphony owns the full git lifecycle —
  agents write code, Symphony manages branches, commits, pushes, and PRs.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Basic operations
  # ---------------------------------------------------------------------------

  @spec current_branch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(workspace) do
    case git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> {:ok, String.trim(branch)}
      error -> error
    end
  end

  @spec checkout_main(String.t()) :: :ok | {:error, term()}
  def checkout_main(workspace) do
    case git(workspace, ["checkout", "main"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec create_branch(String.t(), String.t()) :: :ok | {:error, term()}
  def create_branch(workspace, branch_name) do
    case git(workspace, ["checkout", "-b", branch_name]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec checkout(String.t(), String.t()) :: :ok | {:error, term()}
  def checkout(workspace, branch_name) do
    case git(workspace, ["checkout", branch_name]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Branch naming convention
  # ---------------------------------------------------------------------------

  @max_slug_length 50

  @spec branch_name(String.t(), integer(), String.t()) :: String.t()
  def branch_name(task_id, position, title) do
    slug = slugify(title)
    "symphony/#{task_id}/step-#{position}-#{slug}"
  end

  @spec slugify(String.t()) :: String.t()
  def slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_slug_length)
    |> String.trim_trailing("-")
  end

  # ---------------------------------------------------------------------------
  # Stacked branch creation
  # ---------------------------------------------------------------------------

  @spec create_stacked_branch(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_stacked_branch(workspace, base_branch, new_branch) do
    with :ok <- checkout(workspace, base_branch),
         :ok <- create_branch(workspace, new_branch) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Change detection
  # ---------------------------------------------------------------------------

  @spec has_changes?(String.t()) :: boolean()
  def has_changes?(workspace) do
    case git(workspace, ["status", "--porcelain"]) do
      {:ok, output} -> String.trim(output) != ""
      {:error, _} -> false
    end
  end

  @spec changed_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_files(workspace) do
    # Include both staged and unstaged changes, plus untracked files
    case git(workspace, ["status", "--porcelain"]) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            # status --porcelain format: "XY filename" or "XY filename -> renamed"
            line
            |> String.slice(3..-1//1)
            |> String.split(" -> ")
            |> List.last()
          end)

        {:ok, files}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Commit and push
  # ---------------------------------------------------------------------------

  @spec stage_and_commit(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def stage_and_commit(workspace, message) do
    with {:ok, _} <- git(workspace, ["add", "-A"]),
         {:ok, _output} <- git(workspace, ["commit", "-m", message]) do
      case git(workspace, ["rev-parse", "HEAD"]) do
        {:ok, sha} -> {:ok, String.trim(sha)}
        error -> error
      end
    else
      {:error, {:git_failed, _code, output}} = error ->
        if String.contains?(output, "nothing to commit") do
          {:error, :nothing_to_commit}
        else
          error
        end
    end
  end

  @spec push(String.t(), String.t()) :: :ok | {:error, term()}
  def push(workspace, branch_name) do
    case git(workspace, ["push", "-u", "origin", branch_name]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec force_push(String.t(), String.t()) :: :ok | {:error, term()}
  def force_push(workspace, branch_name) do
    case git(workspace, ["push", "--force-with-lease", "-u", "origin", branch_name]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Rebase operations
  # ---------------------------------------------------------------------------

  @spec rebase_onto(String.t(), String.t()) :: :ok | {:error, :conflict}
  def rebase_onto(workspace, target) do
    case git(workspace, ["rebase", target]) do
      {:ok, _} ->
        :ok

      {:error, {:git_failed, _code, _output}} ->
        # Abort the failed rebase to leave workspace clean
        case git(workspace, ["rebase", "--abort"]) do
          {:ok, _} ->
            :ok

          {:error, abort_err} ->
            Logger.error(
              "Failed to abort rebase workspace=#{workspace} error=#{inspect(abort_err)}"
            )
        end

        {:error, :conflict}
    end
  end

  @spec rebase_stack_onto_main(String.t(), [String.t()]) ::
          :ok | {:error, {:conflict, String.t()}} | {:error, term()}
  def rebase_stack_onto_main(workspace, branch_names) when is_list(branch_names) do
    rebase_stack(workspace, "main", branch_names)
  end

  defp rebase_stack(_workspace, _base, []), do: :ok

  defp rebase_stack(workspace, base, [branch | rest]) do
    with :ok <- checkout(workspace, branch),
         :ok <- rebase_onto(workspace, base) do
      rebase_stack(workspace, branch, rest)
    else
      {:error, :conflict} ->
        {:error, {:conflict, branch}}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Diff operations
  # ---------------------------------------------------------------------------

  @spec diff(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def diff(workspace, base_ref, head_ref) do
    git(workspace, ["diff", "#{base_ref}..#{head_ref}"])
  end

  @spec diff_stat(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def diff_stat(workspace, base_ref, head_ref) do
    git(workspace, ["diff", "--stat", "#{base_ref}..#{head_ref}"])
  end

  @spec diff_name_only(String.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def diff_name_only(workspace, base_ref, head_ref) do
    case git(workspace, ["diff", "--name-only", "#{base_ref}..#{head_ref}"]) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Reset operations
  # ---------------------------------------------------------------------------

  @spec reset_hard(String.t()) :: :ok | {:error, term()}
  def reset_hard(workspace) do
    case git(workspace, ["reset", "--hard", "HEAD"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec clean(String.t()) :: :ok | {:error, term()}
  def clean(workspace) do
    case git(workspace, ["clean", "-fd"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp git(workspace, args) do
    full_args = ["-C", workspace] ++ args

    case System.cmd("git", full_args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        Logger.warning(
          "Git command failed cmd=git #{Enum.join(args, " ")} exit_code=#{exit_code}"
        )

        {:error, {:git_failed, exit_code, String.trim(output)}}
    end
  end
end
