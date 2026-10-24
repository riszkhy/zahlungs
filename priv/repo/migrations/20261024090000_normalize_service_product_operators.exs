defmodule Zahlungs.Repo.Migrations.NormalizeServiceProductOperators do
  use Ecto.Migration

  # `service_products.operator` was free text; it becomes one of the brand
  # keys in Zahlungs.Services.Brand. Known spellings are mapped (the same
  # aliases Brand.normalize/1 knows, matched on lowercase letters and digits
  # only); anything else is cleared, and the product shows under "Lainnya".
  # The old text isn't kept, so `down` leaves the keys as they are.

  @aliases [
    {"telkomsel", ~w(telkomsel tsel simpati kartuas loop)},
    {"byu", ~w(byu)},
    {"indosat", ~w(indosat indosatooredoo ooredoo isat im3 mentari)},
    {"xl", ~w(xl xlaxiata)},
    {"axis", ~w(axis)},
    {"tri", ~w(tri three 3)},
    {"smartfren", ~w(smartfren smart)}
  ]

  def up do
    squeezed = "LOWER(REGEXP_REPLACE(operator, '[^A-Za-z0-9]', ''))"

    for {brand, names} <- @aliases do
      list = Enum.map_join(names, ", ", &"'#{&1}'")
      execute("UPDATE service_products SET operator = '#{brand}' WHERE #{squeezed} IN (#{list})")
    end

    keys = @aliases |> Enum.map(&elem(&1, 0)) |> Enum.map_join(", ", &"'#{&1}'")

    execute(
      "UPDATE service_products SET operator = NULL WHERE operator IS NOT NULL AND operator NOT IN (#{keys})"
    )
  end

  def down, do: :ok
end
