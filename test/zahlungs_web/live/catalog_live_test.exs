defmodule ZahlungsWeb.CatalogLiveTest do
  @moduledoc """
  Catalog browse tests: access and initial render via `get/2`, and search,
  filters, scanning and paging by driving the LiveView's callbacks (see
  `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import ZahlungsWeb.LiveDriver

  alias ZahlungsWeb.CatalogLive

  # Tests share the database with real catalog rows, so they look products up by
  # a unique name instead of expecting them on the first page.
  defp unique_name(label), do: "#{label} #{System.unique_integer([:positive])}"

  defp ids(socket), do: Enum.map(socket.assigns.products, & &1.id)

  describe "/catalog" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/catalog")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "renders the search and barcode-scan affordances", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/catalog")
      response = html_response(conn, 200)
      assert response =~ "Catalog"
      assert response =~ "Scan barcode"
      assert response =~ "Search name / SKU / barcode"
    end
  end

  describe "search and filters" do
    test "search finds active products by name and renders them" do
      product = product_fixture(name: unique_name("Visible Widget"), stock: 10)

      socket =
        CatalogLive |> mount_live(user_fixture()) |> event("filter", %{"search" => product.name})

      assert ids(socket) == [product.id]
      assert socket.assigns.total == 1
      assert html(socket) =~ product.name
    end

    test "inactive products are never listed" do
      product = product_fixture(name: unique_name("Hidden Widget"))
      {:ok, _} = Zahlungs.Catalog.set_product_active(product, false)

      socket =
        CatalogLive |> mount_live(user_fixture()) |> event("filter", %{"search" => product.name})

      assert ids(socket) == []
    end

    test "category and in-stock filters narrow the list" do
      category = category_fixture()
      label = unique_name("Filtered")
      in_stock = product_fixture(name: "#{label} A", stock: 5, category_id: category.id)
      sold_out = product_fixture(name: "#{label} B", stock: 0, category_id: category.id)
      elsewhere = product_fixture(name: "#{label} C", stock: 5)

      socket = mount_live(CatalogLive, user_fixture())

      by_category =
        event(socket, "filter", %{"search" => label, "category_id" => "#{category.id}"})

      assert Enum.sort(ids(by_category)) == Enum.sort([in_stock.id, sold_out.id])

      available =
        event(socket, "filter", %{
          "search" => label,
          "category_id" => "#{category.id}",
          "in_stock" => "true"
        })

      assert ids(available) == [in_stock.id]

      everything = event(socket, "filter", %{"search" => label, "category_id" => ""})
      assert Enum.sort(ids(everything)) == Enum.sort([in_stock.id, sold_out.id, elsewhere.id])
    end
  end

  describe "barcode scan" do
    test "a known code becomes the search and beeps ok" do
      product = product_fixture()

      socket =
        CatalogLive |> mount_live(user_fixture()) |> event("scan", %{"q" => " #{product.sku} "})

      assert socket.assigns.search == product.sku
      assert ids(socket) == [product.id]
      assert pushed_events(socket) == [{"beep", %{type: "ok"}}]
    end

    test "an unknown code beeps an error and says so (hardware scanners submit the form)" do
      code = "NO-SUCH-#{System.unique_integer([:positive])}"
      socket = CatalogLive |> mount_live(user_fixture()) |> event("scan", %{"search" => code})

      assert ids(socket) == []
      assert pushed_events(socket) == [{"beep", %{type: "error"}}]
      assert flash(socket, :error) =~ code
    end
  end

  describe "paging" do
    test "shows 12 per page and clamps out-of-range pages" do
      label = unique_name("Paged")
      for n <- 1..13, do: product_fixture(name: "#{label} #{n}")

      socket =
        CatalogLive |> mount_live(user_fixture()) |> event("filter", %{"search" => label})

      assert socket.assigns.total == 13
      assert socket.assigns.total_pages == 2
      assert length(socket.assigns.products) == 12

      # The Prev/Next buttons push the page as a JSON number.
      assert event(socket, "page", %{"to" => 2}).assigns.page == 2

      last = event(socket, "page", %{"to" => "99"})
      assert last.assigns.page == 2
      assert length(last.assigns.products) == 1
      assert ids(last) -- ids(socket) == ids(last)

      assert event(last, "page", %{"to" => "0"}).assigns.page == 1
    end
  end
end
