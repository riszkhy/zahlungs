defmodule Zahlungs.SeedsTest do
  use Zahlungs.DataCase, async: false

  import ExUnit.CaptureIO

  alias Zahlungs.{Accounts, Catalog, Scope, Stores}

  test "the seed script runs and leaves the dev cashier and sample stock in an active store" do
    capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)

    store = Stores.default_store()
    assert store

    cashier = Accounts.get_user_by_email("cashier@zahlungs.test")
    assert Scope.usable?(Scope.for_user(cashier))

    assert Catalog.get_product_by_code(
             Scope.for_store(Stores.get_store!(cashier.store_id)),
             "DRK-001"
           )
  end
end
