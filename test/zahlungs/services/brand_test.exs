defmodule Zahlungs.Services.BrandTest do
  @moduledoc "Mobile brands for pulsa and paket data: names, numbers, and SBI's labels."
  use ExUnit.Case, async: true

  alias Zahlungs.Services.Brand

  describe "detect/1" do
    test "knows a brand by the number's first four digits" do
      assert Brand.detect("081234567890") == "telkomsel"
      assert Brand.detect("0852-1234-5678") == "telkomsel"
      assert Brand.detect("085712345678") == "indosat"
      assert Brand.detect("081712345678") == "xl"
      assert Brand.detect("087812345678") == "xl"
      assert Brand.detect("083812345678") == "axis"
      assert Brand.detect("089612345678") == "tri"
      assert Brand.detect("088112345678") == "smartfren"
    end

    test "reads +62 and 62 as 0" do
      assert Brand.detect("+6281234567890") == "telkomsel"
      assert Brand.detect("62 857 1234 5678") == "indosat"
    end

    test "is nil for too few digits or a number no brand uses" do
      assert Brand.detect("081") == nil
      assert Brand.detect("") == nil
      assert Brand.detect(nil) == nil
      assert Brand.detect("0217654321") == nil
    end
  end

  describe "normalize/1" do
    test "turns the names people type into a brand" do
      for {typed, brand} <- [
            {"Telkomsel", "telkomsel"},
            {"TSEL", "telkomsel"},
            {"simPATI", "telkomsel"},
            {"by.U", "byu"},
            {"BYU", "byu"},
            {"Indosat Ooredoo", "indosat"},
            {"IM3", "indosat"},
            {"XL Axiata", "xl"},
            {"Axis", "axis"},
            {"Three", "tri"},
            {"tri", "tri"},
            {"Smartfren", "smartfren"},
            {"smart", "smartfren"}
          ] do
        assert Brand.normalize(typed) == brand, "#{typed} → #{inspect(Brand.normalize(typed))}"
      end
    end

    test "is nil for anything else" do
      assert Brand.normalize("") == nil
      assert Brand.normalize(nil) == nil
      assert Brand.normalize("Nokia") == nil
    end
  end

  test "from_sbi/2 trusts SBI's category before its prefix list" do
    assert Brand.from_sbi("TELKOMSEL", "TELKOMSEL H2H") == "telkomsel"
    assert Brand.from_sbi("TELKOMSEL", "TELKOMSEL BYU") == "byu"
    assert Brand.from_sbi("XL,AXIS", "AXIS NASIONAL") == "axis"
    assert Brand.from_sbi("XL,AXIS", "XL DATA COMBO") == "xl"
    assert Brand.from_sbi("", "THREE NASIONAL") == "tri"
    assert Brand.from_sbi("SMARTFREN", "SMART DATA UNLIMITED") == "smartfren"
    assert Brand.from_sbi(nil, "PLN PRABAYAR") == nil
  end

  test "options/0 and label/1 name the brands in order" do
    assert Brand.options() == [
             {"Telkomsel", "telkomsel"},
             {"by.U", "byu"},
             {"Indosat", "indosat"},
             {"XL", "xl"},
             {"Axis", "axis"},
             {"Tri", "tri"},
             {"Smartfren", "smartfren"}
           ]

    assert Brand.label("byu") == "by.U"
    assert Brand.label(nil) == "Lainnya"
  end
end
