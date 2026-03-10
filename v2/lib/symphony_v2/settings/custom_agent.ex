defmodule SymphonyV2.Settings.CustomAgent do
  @moduledoc """
  Schema for user-defined custom agent configurations persisted in the database.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "custom_agents" do
    field :name, :string
    field :command, :string
    field :prompt_flag, :string
    field :skip_permissions_flag, :string
    field :env_vars, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name command prompt_flag)a
  @optional_fields ~w(skip_permissions_flag env_vars)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = agent, attrs) do
    agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 50)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message: "must be lowercase with underscores"
    )
    |> validate_length(:command, min: 1)
    |> validate_length(:prompt_flag, min: 1)
    |> unique_constraint(:name)
  end
end
