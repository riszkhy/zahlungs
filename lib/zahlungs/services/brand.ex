defmodule Zahlungs.Services.Brand do
  @moduledoc """
  Mobile brands for pulsa and paket data: the fixed list a product's
  `operator` is one of, the brand a number belongs to (by its first four
  digits), and SBI's labels for them.

  A number that moved to another operator keeps its prefix, so detection is
  a suggestion the cashier can override; by.U numbers use Telkomsel's
  prefixes and are picked by hand.
  """

  @brands [
    {"Telkomsel", "telkomsel"},
    {"by.U", "byu"},
    {"Indosat", "indosat"},
    {"XL", "xl"},
    {"Axis", "axis"},
    {"Tri", "tri"},
    {"Smartfren", "smartfren"}
  ]

  @prefixes %{
    "telkomsel" => ~w(0811 0812 0813 0821 0822 0823 0851 0852 0853),
    "indosat" => ~w(0814 0815 0816 0855 0856 0857 0858),
    "xl" => ~w(0817 0818 0819 0859 0877 0878),
    "axis" => ~w(0831 0832 0833 0838),
    "tri" => ~w(0895 0896 0897 0898 0899),
    "smartfren" => ~w(0881 0882 0883 0884 0885 0886 0887 0888 0889)
  }

  @by_prefix for {brand, prefixes} <- @prefixes,
                 prefix <- prefixes,
                 into: %{},
                 do: {prefix, brand}

  # What people (and old data) call each brand, squeezed to lowercase letters
  # and digits.
  @aliases %{
    "telkomsel" => "telkomsel",
    "tsel" => "telkomsel",
    "simpati" => "telkomsel",
    "kartuas" => "telkomsel",
    "loop" => "telkomsel",
    "byu" => "byu",
    "indosat" => "indosat",
    "indosatooredoo" => "indosat",
    "ooredoo" => "indosat",
    "isat" => "indosat",
    "im3" => "indosat",
    "mentari" => "indosat",
    "xl" => "xl",
    "xlaxiata" => "xl",
    "axis" => "axis",
    "tri" => "tri",
    "three" => "tri",
    "3" => "tri",
    "smartfren" => "smartfren",
    "smart" => "smartfren"
  }

  @doc "The brands as `{label, key}` options, in the order they are shown."
  def options, do: @brands

  @doc "The brand keys."
  def keys, do: Enum.map(@brands, &elem(&1, 1))

  @doc "A brand's label; a product with no brand is under \"Lainnya\"."
  def label(nil), do: "Lainnya"

  def label(key) do
    Enum.find_value(@brands, key, fn {label, value} -> if value == key, do: label end)
  end

  @doc """
  The brand a mobile number belongs to, by its first four digits (`+62` and
  `62` read as `0`), or nil when there are fewer digits or no brand uses them.
  """
  def detect(number) when is_binary(number) do
    digits = String.replace(number, ~r/\D/, "")

    local =
      case digits do
        "62" <> rest -> "0" <> rest
        other -> other
      end

    if String.length(local) >= 4, do: Map.get(@by_prefix, String.slice(local, 0, 4))
  end

  def detect(_number), do: nil

  @doc ~s|The brand a typed name stands for (`"TSEL"`, `"by.U"`, `"Indosat Ooredoo"`), or nil.|
  def normalize(name) when is_binary(name) do
    whole = squeeze(name)
    first = name |> String.split(~r/\s+/, trim: true) |> List.first() |> squeeze()
    Map.get(@aliases, whole) || Map.get(@aliases, first)
  end

  def normalize(_name), do: nil

  @doc """
  The brand of an SBI price-list item: its category first ("TELKOMSEL BYU" is
  by.U, "AXIS NASIONAL" is Axis even when the prefix list says "XL,AXIS"),
  then the first name in its prefix list.
  """
  def from_sbi(prefix, category) do
    category = category || ""

    cond do
      String.contains?(String.upcase(category), "BYU") -> "byu"
      brand = normalize(category) -> brand
      true -> prefix |> to_string() |> String.split(",") |> List.first() |> normalize()
    end
  end

  defp squeeze(nil), do: ""
  defp squeeze(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end
