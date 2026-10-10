defmodule Zahlungs.LocalTimeTest do
  use ExUnit.Case, async: true

  alias Zahlungs.LocalTime

  # Tests run with the default offset (7 = WIB).

  test "to_local/1 shifts a stored UTC timestamp to shop-local time" do
    assert LocalTime.to_local(~N[2026-01-01 18:30:00]) == ~N[2026-01-02 01:30:00]
    assert LocalTime.to_local(~U[2026-01-01 18:30:00Z]) == ~N[2026-01-02 01:30:00]
    assert LocalTime.to_local(nil) == nil
  end

  test "day_range/2 returns the UTC bounds of the shop-local days" do
    assert LocalTime.day_range(~D[2026-01-02], ~D[2026-01-03]) ==
             {~N[2026-01-01 17:00:00], ~N[2026-01-03 16:59:59]}
  end

  test "today/0 is the date of the shop-local clock" do
    assert LocalTime.today() == NaiveDateTime.to_date(LocalTime.now())
    assert Date.diff(LocalTime.today(), Date.utc_today()) in [0, 1]
  end
end
