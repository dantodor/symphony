defmodule SymphonyV2.Accounts.UserTest do
  use SymphonyV2.DataCase, async: true

  alias SymphonyV2.Accounts.User

  import SymphonyV2.AccountsFixtures

  describe "email_changeset/3" do
    test "valid email change produces a valid changeset" do
      user = user_fixture()
      new_email = unique_user_email()

      changeset = User.email_changeset(user, %{email: new_email})

      assert changeset.valid?
      assert get_change(changeset, :email) == new_email
    end

    test "returns error when email did not change" do
      user = user_fixture()

      changeset = User.email_changeset(user, %{email: user.email})

      refute changeset.valid?
      assert %{email: errors} = errors_on(changeset)
      assert "did not change" in errors
    end

    test "skips uniqueness and did-not-change validation when validate_unique is false" do
      user = user_fixture()

      # With validate_unique: false, even the same email should pass
      # because validate_email_changed is only called in the validate_unique path
      changeset = User.email_changeset(user, %{email: user.email}, validate_unique: false)

      assert changeset.valid?
    end

    test "requires email" do
      user = user_fixture()

      changeset = User.email_changeset(user, %{email: nil})

      refute changeset.valid?
      assert %{email: errors} = errors_on(changeset)
      assert "can't be blank" in errors
    end

    test "validates email format" do
      user = user_fixture()

      changeset = User.email_changeset(user, %{email: "not-an-email"})

      refute changeset.valid?
      assert %{email: errors} = errors_on(changeset)
      assert "must have the @ sign and no spaces" in errors
    end
  end
end
