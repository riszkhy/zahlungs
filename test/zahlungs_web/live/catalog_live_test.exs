defmodule ZahlungsWeb.CatalogLiveTest do
  @moduledoc """
  Tests the catalog browse page via the disconnected render (`get/2`) so we don't
  need the `lazy_html` dependency required by the connected LiveView helpers.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures

  describe "/catalog" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/catalog")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "lists active products for authenticated users", %{conn: conn} do
      _product = product_fixture(name: "Visible Widget", stock: 10)
      conn = conn |> log_in_user(user_fixture()) |> get("/catalog")
      response = html_response(conn, 200)
      assert response =~ "Catalog"
      assert response =~ "Visible Widget"
    end

    test "does not list inactive products", %{conn: conn} do
      product = product_fixture(name: "Hidden Widget")
      {:ok, _} = Zahlungs.Catalog.set_product_active(product, false)
      conn = conn |> log_in_user(user_fixture()) |> get("/catalog")
      refute html_response(conn, 200) =~ "Hidden Widget"
    end
  end
end
