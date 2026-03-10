defmodule SymphonyV2.MockAgentHelper do
  @moduledoc """
  Test helpers for creating mock agent scripts that simulate real agent behavior.

  These shell scripts are used as `command_override` values in agent tests,
  replacing real agent CLI invocations with controlled behavior.
  """

  @doc """
  Creates a mock agent script that writes a valid plan.json and exits 0.

  ## Options

  - `:subtasks` — list of subtask maps (default: single claude_code subtask)
  """
  @spec create_planning_script(String.t(), keyword()) :: String.t()
  def create_planning_script(workspace, opts \\ []) do
    subtasks =
      Keyword.get(opts, :subtasks, [
        %{
          "position" => 1,
          "title" => "Implement feature",
          "spec" => "Write the code for the feature as specified.",
          "agent_type" => "claude_code"
        }
      ])

    plan_data = %{"tasks" => subtasks}
    plan_json = Jason.encode!(plan_data)
    plan_path = Path.join(workspace, "plan.json")
    create_script(workspace, "planning_agent.sh", write_file_script(plan_path, plan_json))
  end

  @doc """
  Creates a mock agent script that writes a review.json and exits 0.

  ## Options

  - `:verdict` — "approved" or "rejected" (default: "approved")
  - `:reasoning` — review reasoning text
  - `:issues` — list of issue maps (default: [])
  """
  @spec create_review_script(String.t(), keyword()) :: String.t()
  def create_review_script(workspace, opts \\ []) do
    verdict = Keyword.get(opts, :verdict, "approved")
    reasoning = Keyword.get(opts, :reasoning, "The implementation satisfies the specification.")
    issues = Keyword.get(opts, :issues, [])

    review_data = %{
      "verdict" => verdict,
      "reasoning" => reasoning,
      "issues" => issues
    }

    review_json = Jason.encode!(review_data)
    review_path = Path.join(workspace, "review.json")
    create_script(workspace, "review_agent.sh", write_file_script(review_path, review_json))
  end

  @doc """
  Creates a mock agent script that writes a file to the workspace and exits 0.
  Simulates an executing agent making code changes.

  ## Options

  - `:filename` — file to create (default: "lib/feature.ex")
  - `:content` — file content (default: simple module)
  """
  @spec create_coding_script(String.t(), keyword()) :: String.t()
  def create_coding_script(workspace, opts \\ []) do
    filename = Keyword.get(opts, :filename, "lib/feature.ex")
    content = Keyword.get(opts, :content, "defmodule Feature do\n  def hello, do: :world\nend\n")

    file_path = Path.join(workspace, filename)

    script_content = """
    #!/bin/bash
    mkdir -p "$(dirname "#{file_path}")"
    cat > "#{file_path}" << 'CONTENT_EOF'
    #{content}
    CONTENT_EOF
    """

    create_script(workspace, "coding_agent.sh", script_content)
  end

  @doc """
  Creates a mock agent script that exits with the given exit code.
  """
  @spec create_failing_script(String.t(), non_neg_integer()) :: String.t()
  def create_failing_script(workspace, exit_code \\ 1) do
    create_script(workspace, "failing_agent.sh", """
    #!/bin/bash
    echo "Agent failed with an error"
    exit #{exit_code}
    """)
  end

  @doc """
  Creates a mock agent script that sleeps for a long time (for timeout testing).
  """
  @spec create_slow_script(String.t(), non_neg_integer()) :: String.t()
  def create_slow_script(workspace, sleep_seconds \\ 30) do
    create_script(workspace, "slow_agent.sh", """
    #!/bin/bash
    sleep #{sleep_seconds}
    """)
  end

  @doc """
  Creates a mock agent script that produces large output.
  """
  @spec create_large_output_script(String.t(), non_neg_integer()) :: String.t()
  def create_large_output_script(workspace, lines \\ 10_000) do
    create_script(workspace, "large_output_agent.sh", """
    #!/bin/bash
    for i in $(seq 1 #{lines}); do
      echo "Output line $i: $(head -c 100 /dev/urandom | base64 | head -c 80)"
    done
    """)
  end

  @doc """
  Creates a mock coding agent script that writes code on the first call,
  and different code on subsequent calls (for retry testing).

  Uses a counter file to track call count.
  """
  @spec create_retry_coding_script(String.t(), keyword()) :: String.t()
  def create_retry_coding_script(workspace, opts \\ []) do
    filename = Keyword.get(opts, :filename, "lib/feature.ex")
    file_path = Path.join(workspace, filename)
    counter_path = Path.join(workspace, ".agent_call_count")

    first_content =
      Keyword.get(opts, :first_content, """
      defmodule Feature do
        # Intentionally broken
        def hello, do: raise "not implemented"
      end
      """)

    retry_content =
      Keyword.get(opts, :retry_content, """
      defmodule Feature do
        def hello, do: :world
      end
      """)

    create_script(workspace, "retry_coding_agent.sh", """
    #!/bin/bash
    # Track call count
    if [ -f "#{counter_path}" ]; then
      COUNT=$(cat "#{counter_path}")
      COUNT=$((COUNT + 1))
    else
      COUNT=1
    fi
    echo $COUNT > "#{counter_path}"

    mkdir -p "$(dirname "#{file_path}")"

    if [ $COUNT -eq 1 ]; then
      cat > "#{file_path}" << 'CONTENT_EOF'
    #{first_content}
    CONTENT_EOF
    else
      cat > "#{file_path}" << 'CONTENT_EOF'
    #{retry_content}
    CONTENT_EOF
    fi
    """)
  end

  # --- Private helpers ---

  defp create_script(workspace, name, content) do
    # Use a unique subdirectory for scripts to avoid collisions
    scripts_dir = Path.join(workspace, ".symphony_scripts")
    File.mkdir_p!(scripts_dir)
    script_path = Path.join(scripts_dir, name)
    File.write!(script_path, content)
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp write_file_script(file_path, content) do
    """
    #!/bin/bash
    cat > "#{file_path}" << 'FILE_EOF'
    #{content}
    FILE_EOF
    """
  end
end
