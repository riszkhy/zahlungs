defmodule Zahlungs.Repo.Migrations.FillServiceProductBrandsFromNames do
  use Ecto.Migration

  # Pulsa and paket data products made before brands had none, so the
  # cashier screen couldn't tell "TELKOMSEL PULSA 10.000" from "TRI REGULER
  # 10.000". Their brand is taken from the name: the whole name or its first
  # word, squeezed to lowercase letters and digits, against the aliases
  # Zahlungs.Services.Brand.normalize/1 knew then. A name of no known brand is
  # left without one. `down` can't tell these from brands set by hand, so it
  # leaves them.

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

  def up do
    %{rows: rows} =
      repo().query!(
        "SELECT id, name FROM service_products " <>
          "WHERE operator IS NULL AND category IN ('pulsa', 'paket_data')"
      )

    for [id, name] <- rows, brand = brand_of(name) do
      repo().query!("UPDATE service_products SET operator = ? WHERE id = ?", [brand, id])
    end
  end

  def down, do: :ok

  defp brand_of(name) when is_binary(name) do
    first = name |> String.split(~r/\s+/, trim: true) |> List.first()
    Map.get(@aliases, squeeze(name)) || Map.get(@aliases, squeeze(first))
  end

  defp brand_of(_name), do: nil

  defp squeeze(nil), do: ""
  defp squeeze(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end
