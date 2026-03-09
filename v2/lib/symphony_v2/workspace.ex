defmodule SymphonyV2.Workspace do
  @moduledoc """
  Manages per-task workspace directories.

  Each task gets an isolated workspace at `<workspace_root>/task-<task_id>/`.
  The configured repo is cloned into this directory, giving each agent a
  clean copy to work with.
  """

  require Logger

  @doc """
  Creates a workspace directory for the given task ID.

  Returns `{:ok, path}` where path is the absolute workspace directory,
  or `{:error, reason}`.
  """
  @spec create(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create(workspace_root, task_id) when is_binary(workspace_root) and is_binary(task_id) do
    path = workspace_path(workspace_root, task_id) |> Path.expand()

    with :ok <- validate_path(path, workspace_root) do
      case File.mkdir_p(path) do
        :ok ->
          Logger.info("Created workspace workspace=#{path} task_id=#{task_id}")
          {:ok, path}

        {:error, reason} ->
          Logger.error(
            "Failed to create workspace workspace=#{path} task_id=#{task_id} error=#{inspect(reason)}"
          )

          {:error, {:mkdir_failed, reason}}
      end
    end
  end

  @doc """
  Clones the configured repo into the workspace directory.

  Uses `git clone` to create a full copy of the repository.
  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec clone_repo(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def clone_repo(repo_path, workspace_path)
      when is_binary(repo_path) and is_binary(workspace_path) do
    case System.cmd("git", ["clone", repo_path, workspace_path], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("Cloned repo into workspace repo=#{repo_path} workspace=#{workspace_path}")
        {:ok, workspace_path}

      {output, exit_code} ->
        Logger.error(
          "Failed to clone repo repo=#{repo_path} workspace=#{workspace_path} exit_code=#{exit_code} output=#{String.trim(output)}"
        )

        {:error, {:clone_failed, exit_code, String.trim(output)}}
    end
  end

  @doc """
  Validates that the given path is safely under the workspace root.

  Resolves symlinks and checks that the path doesn't escape the root
  via path traversal (`../`), symlinks, or other tricks.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_path(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_path(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(workspace_root)
    root_prefix = expanded_root <> "/"

    cond do
      expanded_path == expanded_root ->
        {:error, {:path_equals_root, expanded_path}}

      not String.starts_with?(expanded_path <> "/", root_prefix) ->
        {:error, {:path_outside_root, expanded_path, expanded_root}}

      true ->
        ensure_no_symlink_escape(expanded_path, expanded_root)
    end
  end

  @doc """
  Removes a workspace directory and all its contents.

  Validates the path is under workspace_root before deletion.
  Returns `{:ok, paths}` or `{:error, reason}`.
  """
  @spec cleanup(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def cleanup(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    with :ok <- validate_path(path, workspace_root) do
      case File.rm_rf(path) do
        {:ok, paths} ->
          Logger.info("Cleaned up workspace workspace=#{path}")
          {:ok, paths}

        {:error, reason, failed_path} ->
          Logger.error(
            "Failed to cleanup workspace workspace=#{path} error=#{inspect(reason)} failed_path=#{failed_path}"
          )

          {:error, {:cleanup_failed, reason, failed_path}}
      end
    end
  end

  @doc """
  Checks if a workspace directory exists for the given task.

  Useful for restart recovery to avoid re-cloning.
  """
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(workspace_root, task_id) when is_binary(workspace_root) and is_binary(task_id) do
    path = workspace_path(workspace_root, task_id)
    File.dir?(path)
  end

  @doc """
  Returns the workspace path for a given task ID.
  """
  @spec workspace_path(String.t(), String.t()) :: String.t()
  def workspace_path(workspace_root, task_id) do
    Path.join(workspace_root, "task-#{task_id}")
  end

  # Walks each path component from root to target, checking for symlinks.
  # If any component is a symlink, it could escape the root.
  defp ensure_no_symlink_escape(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:symlink_in_path, next}}}

        {:ok, _stat} ->
          {:cont, next}

        # Path doesn't exist yet (e.g., workspace not created yet) — that's fine
        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:path_unreadable, next, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _} = error -> error
      _final_path -> :ok
    end
  end
end
