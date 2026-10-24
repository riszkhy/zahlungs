defmodule Zahlungs.ServicesBrandPrefixesTest do
  @moduledoc """
  The mobile number prefixes of each brand, kept by the platform operator for
  every organization. One table for all: not async, so two tests don't
  rewrite it at once.
  """
  use Zahlungs.DataCase, async: false

  alias Zahlungs.Services
  alias Zahlungs.Services.Brand

  setup do
    {:ok, _} = Services.reset_brand_prefixes()
    :ok
  end

  defp form(changes), do: Map.merge(form_of(Brand.default_prefixes()), changes)

  defp form_of(prefixes),
    do: Map.new(prefixes, fn {brand, list} -> {brand, Enum.join(list, ", ")} end)

  test "starts from the defaults" do
    assert Services.brand_prefixes() == Brand.default_prefixes()
  end

  test "saves every brand's prefixes, typed with commas or spaces" do
    assert {:ok, prefixes} =
             Services.save_brand_prefixes(
               form(%{"telkomsel" => "0811,0812  0813;0812", "byu" => " ", "tri" => "0895 0896"})
             )

    assert prefixes["telkomsel"] == ~w(0811 0812 0813)
    assert prefixes["byu"] == []
    assert prefixes["tri"] == ~w(0895 0896)
    assert Services.brand_prefixes() == prefixes
  end

  test "a prefix is four digits starting with 08" do
    assert {:error, errors} =
             Services.save_brand_prefixes(form(%{"telkomsel" => "0811, 812, 08a1, 08111"}))

    assert errors["telkomsel"] =~ "812"
    assert errors["telkomsel"] =~ "08a1"
    assert errors["telkomsel"] =~ "08111"
    refute Map.has_key?(errors, "indosat")
    assert Services.brand_prefixes() == Brand.default_prefixes()
  end

  test "a prefix belongs to one brand only, and nothing is saved otherwise" do
    assert {:error, errors} =
             Services.save_brand_prefixes(form(%{"byu" => "0812, 0814"}))

    assert errors["byu"] =~ "0812"
    assert errors["byu"] =~ "Telkomsel"
    assert errors["byu"] =~ "0814"
    assert errors["byu"] =~ "Indosat"
    assert Services.brand_prefixes() == Brand.default_prefixes()
  end

  test "a brand left out of the form has no prefixes" do
    assert {:ok, prefixes} = Services.save_brand_prefixes(%{"telkomsel" => "0811"})
    assert prefixes["telkomsel"] == ["0811"]
    assert prefixes["indosat"] == []
  end

  test "reset_brand_prefixes/0 brings the defaults back" do
    {:ok, _} = Services.save_brand_prefixes(%{"telkomsel" => "0811"})
    assert {:ok, prefixes} = Services.reset_brand_prefixes()
    assert prefixes == Brand.default_prefixes()
    assert Services.brand_prefixes() == Brand.default_prefixes()
  end
end
