defmodule SymphonyV2.GitTestHelper do
  @moduledoc """
  Test helper for creating temporary git repositories.

  Creates temp directories with initialized git repos for testing git operations.
  Optionally sets up a bare remote for push testing.
  """

  @doc """
  Creates a temporary directory with an initialized git repo and an initial commit.

  Returns `{:ok, repo_path}`.
  """
  @spec init_temp_repo(String.t()) :: {:ok, String.t()}
  def init_temp_repo(tmp_dir) do
    repo_path = Path.join(tmp_dir, "test-repo")
    File.mkdir_p!(repo_path)

    git!(repo_path, ["init", "--initial-branch=main"])
    git!(repo_path, ["config", "user.email", "test@example.com"])
    git!(repo_path, ["config", "user.name", "Test User"])

    # Create an initial file and commit
    File.write!(Path.join(repo_path, "README.md"), "# Test Repo\n")
    git!(repo_path, ["add", "-A"])
    git!(repo_path, ["commit", "-m", "Initial commit"])

    {:ok, repo_path}
  end

  @doc """
  Creates a temp repo with a bare remote for push testing.

  Returns `{:ok, repo_path, remote_path}`.
  """
  @spec init_temp_repo_with_remote(String.t()) :: {:ok, String.t(), String.t()}
  def init_temp_repo_with_remote(tmp_dir) do
    remote_path = Path.join(tmp_dir, "remote.git")
    File.mkdir_p!(remote_path)

    # Init bare remote
    System.cmd("git", ["init", "--bare", "--initial-branch=main", remote_path],
      stderr_to_stdout: true
    )

    # Init working repo
    repo_path = Path.join(tmp_dir, "test-repo")
    File.mkdir_p!(repo_path)

    git!(repo_path, ["init", "--initial-branch=main"])
    git!(repo_path, ["config", "user.email", "test@example.com"])
    git!(repo_path, ["config", "user.name", "Test User"])

    # Create initial commit and push to remote
    File.write!(Path.join(repo_path, "README.md"), "# Test Repo\n")
    git!(repo_path, ["add", "-A"])
    git!(repo_path, ["commit", "-m", "Initial commit"])
    git!(repo_path, ["remote", "add", "origin", remote_path])
    git!(repo_path, ["push", "-u", "origin", "main"])

    {:ok, repo_path, remote_path}
  end

  @doc """
  Writes a file and commits it in the given repo.
  """
  @spec write_and_commit(String.t(), String.t(), String.t(), String.t()) :: :ok
  def write_and_commit(repo_path, file_name, content, message) do
    File.write!(Path.join(repo_path, file_name), content)
    git!(repo_path, ["add", "-A"])
    git!(repo_path, ["commit", "-m", message])
    :ok
  end

  @doc """
  Runs a git command in the repo, raises on failure.
  """
  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(repo_path, args) do
    {output, 0} = System.cmd("git", ["-C", repo_path] ++ args, stderr_to_stdout: true)
    output
  end
end
