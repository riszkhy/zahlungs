defmodule Zahlungs.Repo.Migrations.TidySbiBillDetails do
  use Ecto.Migration

  # A paid bill keeps its reference and the meter's reading for the receipt, and
  # what was stored before they were read is put right: the customer's name was
  # SBI's whole text ("Nama:BUDI SANTOSO/Tarif daya:R1 450/Ref:..."), and the rest
  # can still be read from the answer kept on the service.
  def up do
    alter table(:service_transactions) do
      add :bill_reference, :string, size: 64
      add :meter_reading, :string, size: 40
    end

    flush()

    execute(name_sql("service_transactions"))
    execute(name_sql("service_inquiries"))

    flush()

    %{rows: rows} =
      repo().query!(
        "SELECT id, provider_payload FROM service_transactions " <>
          "WHERE status = 'success' AND channel = 'api' AND category = 'tagihan' " <>
          "AND provider_payload IS NOT NULL",
        [],
        skip_org_id: true
      )

    Enum.each(rows, fn [id, payload] ->
      repo().query!(
        "UPDATE service_transactions SET bill_reference = ?, meter_reading = ? WHERE id = ?",
        [bill_reference(payload), meter_reading(payload), id],
        skip_org_id: true
      )
    end)
  end

  def down do
    alter table(:service_transactions) do
      remove :bill_reference
      remove :meter_reading
    end
  end

  def name_sql(table) do
    "UPDATE #{table} " <>
      "SET customer_name = TRIM(SUBSTRING_INDEX(SUBSTRING(customer_name, 6), '/', 1)) " <>
      "WHERE customer_name LIKE 'Nama:%'"
  end

  def bill_reference(payload), do: read(payload, ~r/\bRef\s*:\s*([^\/"\\]*)/i, 64)
  def meter_reading(payload), do: read(payload, ~r/\bSt meter\s*:\s*([^\/"\\]*)/i, 40)

  defp read(payload, pattern, max) do
    case Regex.run(pattern, payload) do
      [_, value] ->
        case value |> String.trim() |> String.trim_trailing(".") do
          blank when blank in ["", "-"] -> nil
          found -> String.slice(found, 0, max)
        end

      _ ->
        nil
    end
  end
end
