defmodule Zahlungs.ShiftsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Zahlungs.Shifts` context.
  """

  alias Zahlungs.Shifts

  @doc "Opens a shift for the user. Sales can only be recorded on an open shift."
  def shift_fixture(user, opening_cash \\ 0) do
    {:ok, shift} = Shifts.open_shift(Zahlungs.Scope.for_user(user), opening_cash)
    shift
  end

  @doc "A user who already has an open shift, i.e. one who can record sales."
  def user_on_shift_fixture(attrs \\ %{}) do
    user = Zahlungs.AccountsFixtures.user_fixture(attrs)
    shift_fixture(user)
    user
  end
end
