defmodule ZahlungsWeb.PromotionLiveTest do
  @moduledoc """
  The admin's promotions page and the promotion figures in the sales report.
  Access through `get/2`, behaviour through `ZahlungsWeb.LiveDriver`.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.PromotionsFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{LocalTime, Promotions, Sales}
  alias ZahlungsWeb.PromotionLive

  defp admin do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  test "cashiers are sent away, admins see the page", %{conn: conn} do
    assert conn |> log_in_user(user_fixture()) |> get("/admin/promotions") |> redirected_to() ==
             "/"

    assert conn |> log_in_user(admin()) |> get("/admin/promotions") |> html_response(200) =~
             "Promo"
  end

  test "an admin creates a promotion on a product found by search" do
    product = product_fixture(name: "Sabun Wangi #{System.unique_integer([:positive])}")
    name = "Promo Sabun #{System.unique_integer([:positive])}"
    today = LocalTime.today(default_store())

    socket =
      PromotionLive.Index
      |> mount_live(admin(), action: :new)
      |> event("product_search", %{"q" => product.name})

    assert html(socket) =~ product.name

    socket =
      socket
      |> event("add_product", %{"id" => product.id})
      |> event("save", %{
        "promotion" => %{
          "name" => name,
          "kind" => "percent",
          "value" => "15",
          "starts_on" => Date.to_iso8601(today),
          "ends_on" => Date.to_iso8601(Date.add(today, 3)),
          "all_stores" => "true",
          "active" => "true"
        }
      })

    assert live_redirect(socket) == "/admin/promotions"

    assert %{promotion: promotion} =
             Enum.find(Promotions.list_promotions(), &(&1.promotion.name == name))

    assert Promotions.get_promotion!(promotion.id).product_ids == [product.id]
    assert html(socket) =~ name
  end

  test "a promotion without a target stays on the form" do
    socket =
      PromotionLive.Index
      |> mount_live(admin(), action: :new)
      |> event("save", %{
        "promotion" => %{"name" => "Kosong", "kind" => "percent", "value" => "5"}
      })

    assert is_nil(live_redirect(socket))
    assert html(socket) =~ "pilih minimal satu produk atau kategori"
  end

  test "turning a promotion off, and the cashier discount limit" do
    promotion = promotion_fixture()
    admin = admin()

    socket =
      PromotionLive.Index
      |> mount_live(admin)
      |> event("toggle_active", %{"id" => promotion.id})

    refute Promotions.get_promotion!(promotion.id).active
    assert html(socket) =~ "Nonaktif"

    event(socket, "save_limit", %{"limit" => "10"})

    assert Decimal.equal?(
             Promotions.cashier_discount_limit(admin.organization_id),
             Decimal.new(10)
           )
  end

  test "the sales report shows what promotions took off" do
    user = user_on_shift_fixture()
    product = product_fixture(price: Decimal.new("10000"), stock: 5)
    promotion = promotion_fixture(%{product_ids: [product.id]})

    {:ok, _} =
      Sales.create_sale(user, [%{product_id: product.id, quantity: 1}], %{amount_paid: "9000"})

    html = ZahlungsWeb.ReportLive.Index |> mount_live(admin()) |> html()

    assert html =~ "Potongan promo"
    assert html =~ promotion.name
    assert html =~ "Rp 1.000,00"
  end
end
