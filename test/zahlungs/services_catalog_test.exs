defmodule Zahlungs.ServicesCatalogTest do
  @moduledoc """
  The vendor's catalog: picking products from SBI's price list, and
  refreshing the shop's products from the member's prices. No request
  reaches SBI (`Sbi.StubClient`).
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures

  alias Zahlungs.Services
  alias Zahlungs.Services.CatalogCache
  alias Zahlungs.Services.Provider.Sbi.StubClient

  defp d(value), do: Decimal.new(value)

  @pricelist %{
    "Pulsa Reguler" => [
      %{
        "code" => "T10",
        "name" => "THREE 10.000",
        "harga" => 10_150,
        "gangguan" => "Tidak",
        "tersedia" => "Ya"
      }
    ],
    "PLN Prabayar" => [
      %{
        "code" => "PLN20",
        "name" => "PLN 20.000",
        "harga" => 20_775,
        "gangguan" => "Tidak",
        "tersedia" => "Ya"
      },
      %{
        "code" => "PP20",
        "name" => "PLN TOKEN 20.000",
        "harga" => 20_825,
        "gangguan" => "Ya",
        "tersedia" => "Ya"
      }
    ],
    "Telkomsel Data" => [
      %{
        "code" => "TD1",
        "name" => "TSEL DATA 1GB",
        "harga" => "15000",
        "gangguan" => "Tidak",
        "tersedia" => "Tidak"
      }
    ],
    "PPOB" => [
      %{
        "code" => "PLN",
        "name" => "PLN",
        "admin_amount" => 3000,
        "komisi" => 1000,
        "gangguan" => "Tidak",
        "tersedia" => "Ya"
      }
    ]
  }

  setup do
    account =
      deposit_account_fixture(%{
        mode: "api",
        provider: "sbi",
        credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => "pw"}
      })

    %{account: account}
  end

  describe "search_catalog/2" do
    test "finds SBI's products by every word, with a category hint", ctx do
      StubClient.expect("pricelist", {:ok, 200, @pricelist})

      assert {:ok, items} = Services.search_catalog(ctx.account, "pln 20.000")
      assert items |> Enum.map(& &1.code) |> Enum.sort() == ["PLN20", "PP20"]

      item = Enum.find(items, &(&1.code == "PLN20"))
      assert %{category_hint: "token_pln", status: "normal"} = item
      assert Decimal.equal?(item.price, d("20775"))
    end

    test "brings each product's brand from SBI's prefix and category", ctx do
      StubClient.expect(
        "pricelist",
        {:ok, 200,
         %{
           "Pulsa Reguler" => [
             %{
               "code" => "S10",
               "name" => "TSEL 10",
               "category" => "TELKOMSEL H2H",
               "prefix" => "TELKOMSEL",
               "harga" => 10_100
             },
             %{
               "code" => "BY10",
               "name" => "BYU 10",
               "category" => "TELKOMSEL BYU",
               "prefix" => "TELKOMSEL",
               "harga" => 10_200
             },
             %{
               "code" => "AX10",
               "name" => "AXIS 10",
               "category" => "AXIS NASIONAL",
               "prefix" => "XL,AXIS",
               "harga" => 10_300
             }
           ],
           "PLN Prabayar" => [
             %{
               "code" => "PLN20",
               "name" => "PLN 20.000",
               "category" => "PLN PRABAYAR",
               "prefix" => "",
               "harga" => 20_775
             }
           ]
         }}
      )

      {:ok, items} = Services.search_catalog(ctx.account, "")
      brands = Map.new(items, &{&1.code, &1.brand})

      assert brands == %{"S10" => "telkomsel", "BY10" => "byu", "AX10" => "axis", "PLN20" => nil}
    end

    test "tells data, bills and what can't be sold apart", ctx do
      StubClient.expect("pricelist", {:ok, 200, @pricelist})
      {:ok, items} = Services.search_catalog(ctx.account, "")
      by_code = Map.new(items, &{&1.code, &1})

      assert by_code["T10"].category_hint == "pulsa"
      assert by_code["TD1"].category_hint == "paket_data"
      assert by_code["TD1"].status == "kosong"
      assert by_code["PP20"].status == "gangguan"
      assert %{category_hint: "tagihan", price: nil} = by_code["PLN"]
      assert Decimal.equal?(by_code["PLN"].admin, d("3000"))
      assert Decimal.equal?(by_code["PLN"].commission, d("1000"))
    end

    test "every item of the PPOB group is a Tagihan", ctx do
      pricelist =
        Map.put(
          @pricelist,
          "PPOB",
          for code <- ~w(BPJSKS PDAMSLTG TELKOM PGN PLN) do
            %{
              "code" => code,
              "name" => code,
              "admin_amount" => 2500,
              "gangguan" => "Tidak",
              "tersedia" => "Ya"
            }
          end
        )

      StubClient.expect("pricelist", {:ok, 200, pricelist})
      {:ok, items} = Services.search_catalog(ctx.account, "")
      ppob = Enum.filter(items, &(&1.code in ~w(BPJSKS PDAMSLTG TELKOM PGN PLN)))

      assert length(ppob) == 5
      assert Enum.all?(ppob, &(&1.category_hint == "tagihan"))
    end

    test "no price list is unavailable", ctx do
      StubClient.expect("pricelist", {:error, :timeout})
      assert Services.search_catalog(ctx.account, "pln") == {:error, :unavailable}
    end
  end

  test "the cache keeps a catalog for a while" do
    key = "test-#{System.unique_integer([:positive])}"
    loader = fn -> send(self(), :loaded) && {:ok, [:item]} end

    assert CatalogCache.fetch(key, loader, 60_000) == {:ok, [:item]}
    assert CatalogCache.fetch(key, loader, 60_000) == {:ok, [:item]}
    assert_received :loaded
    refute_received :loaded

    assert CatalogCache.fetch(key, fn -> {:error, :down} end, 0) == {:error, :down}
  end

  test "catalog_account/0 is an active api account whose provider has a catalog", ctx do
    assert Services.catalog_account().id == ctx.account.id
    assert in_org(organization_fixture(), fn -> Services.catalog_account() end) == nil
  end

  describe "price updates" do
    setup do
      pulsa =
        service_product_fixture(%{provider_code: "T10", cost: "10150", margin_value: "1850"})

      gone = service_product_fixture(%{provider_code: "XX99"})
      bill = api_product_fixture(%{provider_code: "PLN"})
      no_code = service_product_fixture()

      StubClient.respond("price", fn %{"product_code" => code} ->
        case code do
          "T10" ->
            {:ok, 200,
             %{
               "data" => %{
                 "kode" => "T10",
                 "harga" => "10300",
                 "gangguan" => "Tidak",
                 "kosong" => "Tidak"
               }
             }}

          "PLN" ->
            {:ok, 200,
             %{
               "data" => %{
                 "kode" => "PLN",
                 "harga" => "",
                 "gangguan" => "Tidak",
                 "kosong" => "Tidak"
               }
             }}

          _ ->
            {:ok, 200, %{"status" => "failed", "message" => "GAGAL, RC:97. Invalid product code"}}
        end
      end)

      %{pulsa: pulsa, gone: gone, bill: bill, no_code: no_code}
    end

    test "show what would change, without saving", ctx do
      assert {:ok, rows} = Services.price_update(ctx.account)
      by_id = Map.new(rows, &{&1.product.id, &1})

      pulsa = by_id[ctx.pulsa.id]
      assert {pulsa.status, Decimal.equal?(pulsa.old_cost, d("10150"))} == {"normal", true}
      assert Decimal.equal?(pulsa.new_cost, d("10300"))
      assert Decimal.equal?(pulsa.new_price, d("12150"))

      assert by_id[ctx.gone.id].status == "tidak_ditemukan"
      assert Decimal.equal?(by_id[ctx.bill.id].new_cost, ctx.bill.cost)
      refute Map.has_key?(by_id, ctx.no_code.id)

      assert Decimal.equal?(Services.get_product!(ctx.pulsa.id).cost, d("10150"))
    end

    test "saving applies the costs and statuses; an unknown code can't be sold", ctx do
      {:ok, rows} = Services.price_update(ctx.account)
      assert {:ok, 3} = Services.apply_price_update(ctx.account, rows)

      pulsa = Services.get_product!(ctx.pulsa.id)
      assert Decimal.equal?(pulsa.cost, d("10300"))
      assert Decimal.equal?(pulsa.provider_price, d("10300"))
      assert {pulsa.provider_status, is_nil(pulsa.provider_checked_at)} == {"normal", false}

      assert Services.get_product!(ctx.gone.id).provider_status == "tidak_ditemukan"

      assign_account(default_store(), ctx.account)
      cashier = user_on_shift_fixture()

      assert Services.record(cashier, ctx.gone.id, %{
               "customer_ref" => "081234567891",
               "amount_paid" => "20000"
             }) == {:error, :product_unavailable}
    end
  end
end
