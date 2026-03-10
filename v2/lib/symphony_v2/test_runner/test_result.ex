defmodule SymphonyV2.TestRunner.TestResult do
  @moduledoc """
  Structured result from running a test command.
  """

  @type t :: %__MODULE__{
          passed: boolean(),
          exit_code: integer(),
          output: String.t(),
          duration_ms: integer()
        }

  @enforce_keys [:passed, :exit_code, :output, :duration_ms]
  defstruct [:passed, :exit_code, :output, :duration_ms]
end
