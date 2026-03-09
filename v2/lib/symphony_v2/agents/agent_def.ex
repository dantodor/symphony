defmodule SymphonyV2.Agents.AgentDef do
  @moduledoc """
  Struct representing a coding agent's CLI configuration.
  Used by the AgentRegistry to build commands for agent execution.
  """

  @type t :: %__MODULE__{
          name: atom(),
          command: String.t(),
          skip_permissions_flag: String.t() | nil,
          prompt_flag: String.t(),
          env_vars: [String.t()]
        }

  @enforce_keys [:name, :command, :prompt_flag]
  defstruct [:name, :command, :skip_permissions_flag, :prompt_flag, env_vars: []]

  @doc "Creates a new AgentDef from a keyword list or map."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs, [:name, :command, :prompt_flag]) do
      {:ok,
       %__MODULE__{
         name: to_atom(attrs[:name] || attrs["name"]),
         command: to_string(attrs[:command] || attrs["command"]),
         skip_permissions_flag: get_string(attrs, :skip_permissions_flag),
         prompt_flag: to_string(attrs[:prompt_flag] || attrs["prompt_flag"]),
         env_vars: get_list(attrs, :env_vars)
       }}
    end
  end

  defp validate_required(attrs, keys) do
    missing =
      Enum.filter(keys, fn key ->
        val = attrs[key] || attrs[to_string(key)]
        is_nil(val) or val == ""
      end)

    case missing do
      [] -> :ok
      keys -> {:error, "missing required fields: #{Enum.join(keys, ", ")}"}
    end
  end

  defp to_atom(val) when is_atom(val), do: val
  defp to_atom(val) when is_binary(val), do: String.to_atom(val)

  defp get_string(attrs, key) do
    val = attrs[key] || attrs[to_string(key)]
    if val, do: to_string(val), else: nil
  end

  defp get_list(attrs, key) do
    case attrs[key] || attrs[to_string(key)] do
      nil -> []
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end
end
