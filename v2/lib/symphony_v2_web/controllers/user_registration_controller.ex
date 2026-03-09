defmodule SymphonyV2Web.UserRegistrationController do
  use SymphonyV2Web, :controller

  alias SymphonyV2.Accounts
  alias SymphonyV2.Accounts.User
  alias SymphonyV2Web.UserAuth

  def new(conn, _params) do
    changeset = Accounts.change_user_email(%User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Account created successfully.")
        |> UserAuth.log_in_user(user, user_params)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end
end
