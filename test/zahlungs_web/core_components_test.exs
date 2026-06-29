defmodule ZahlungsWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  alias ZahlungsWeb.CoreComponents

  describe "format_money/1" do
    test "formats Rupiah with thousands and decimal separators" do
      assert CoreComponents.format_money(Decimal.new("3500")) == "Rp 3.500,00"
      assert CoreComponents.format_money(Decimal.new("12000.5")) == "Rp 12.000,50"
      assert CoreComponents.format_money(Decimal.new("1234567.89")) == "Rp 1.234.567,89"
    end

    test "handles integers, strings, zero and negatives" do
      assert CoreComponents.format_money(1000) == "Rp 1.000,00"
      assert CoreComponents.format_money("2500") == "Rp 2.500,00"
      assert CoreComponents.format_money(Decimal.new(0)) == "Rp 0,00"
      assert CoreComponents.format_money(Decimal.new("-2000")) == "-Rp 2.000,00"
    end
  end
end
