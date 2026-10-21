defmodule Zahlungs.Services.RefTest do
  @moduledoc "The refs Zahlungs sends to a provider: unique across organizations, short."
  use ExUnit.Case, async: true

  alias Zahlungs.Services.Ref

  test "a prefix, the store, the time and six hex digits" do
    assert Ref.generate("Z", 12, ~N[2026-10-21 15:30:00]) =~ ~r/^Z12261021153000[0-9A-F]{6}$/
  end

  test "two refs in the same second differ" do
    now = ~N[2026-10-21 15:30:00]
    refute Ref.generate("Z", 12, now) == Ref.generate("Z", 12, now)
  end

  test "fits in 26 characters for a large store id" do
    assert String.length(Ref.generate("Q", 123_456, ~N[2026-10-21 15:30:00])) <= 26
  end
end
