defmodule Zahlungs.TidySbiBillDetailsMigrationTest do
  @moduledoc """
  The migration that tidies what was stored from SBI before the answers were
  read properly. Not async: its update runs over the whole table.
  """
  use Zahlungs.DataCase, async: false

  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.Repo.Migrations.TidySbiBillDetails
  alias Zahlungs.Services.Transaction

  unless Code.ensure_loaded?(TidySbiBillDetails),
    do: Code.require_file("priv/repo/migrations/20261102100000_tidy_sbi_bill_details.exs")

  @payload ~s({"detail":{"data_1":"Nama:BUDI SANTOSO//Tarif daya:R1/450/Ref:AAAA1111BBBB/Jml bulan:1/Blth:NOV26/St meter:00001000-00001100/Nominal pokok:Rp50000"},"ref_1":"Q1","reference":"BUDI SANTOSO//Ref:AAAA1111BBBB"})

  defp name_of(tx), do: Repo.get!(Transaction, tx.id).customer_name

  defp named(tx, name) do
    Repo.update_all(from(t in Transaction, where: t.id == ^tx.id), set: [customer_name: name])
    tx
  end

  test "keeps the name out of SBI's whole text, and leaves plain names alone" do
    assign_account(default_store(), deposit_account_fixture())
    cashier = user_on_shift_fixture()
    product = service_product_fixture()

    raw =
      cashier
      |> service_fixture(product)
      |> named("Nama:BUDI SANTOSO/Tarif daya:R1 450/Ref:EEEE/Jml bulan:1/Nominal pokok:Rp4")

    plain = cashier |> service_fixture(product) |> named("Anto Nama:Lain")
    none = cashier |> service_fixture(product) |> named(nil)

    Repo.query!(TidySbiBillDetails.name_sql("service_transactions"))

    assert name_of(raw) == "BUDI SANTOSO"
    assert name_of(plain) == "Anto Nama:Lain"
    assert name_of(none) == nil
  end

  test "reads the reference and the reading from a stored answer" do
    assert TidySbiBillDetails.bill_reference(@payload) == "AAAA1111BBBB"
    assert TidySbiBillDetails.meter_reading(@payload) == "00001000-00001100"

    blank = ~s({"msg":"Nama:X/Ref:/St meter:-/Tagihan:Rp1","ref_1":"Q1"})
    assert TidySbiBillDetails.bill_reference(blank) == nil
    assert TidySbiBillDetails.meter_reading(blank) == nil

    assert TidySbiBillDetails.bill_reference(~s({"ref_1":"Q1","reference":"x"})) == nil
  end
end
