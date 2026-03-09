# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#

alias SymphonyV2.Accounts

case Accounts.get_user_by_email("admin@localhost") do
  nil ->
    {:ok, _user} =
      Accounts.register_user(%{
        email: "admin@localhost",
        password: "admin_password_123"
      })

    IO.puts("Created default user: admin@localhost")

  _user ->
    IO.puts("Default user admin@localhost already exists, skipping.")
end
