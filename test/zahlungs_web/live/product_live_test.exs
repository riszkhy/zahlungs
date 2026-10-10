defmodule ZahlungsWeb.ProductLiveTest do
  @moduledoc """
  Admin product management tests: router-level role gating via `get/2`, and the
  list's filters and row actions by driving the LiveView's callbacks (see
  `ZahlungsWeb.LiveDriver`). The create/edit form is a live component and is
  covered through the `Zahlungs.Catalog` context tests.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Catalog
  alias ZahlungsWeb.ProductLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp ids(socket), do: Enum.map(socket.assigns.products, & &1.id)

  describe "/products access control" do
    test "redirects guests to the log in page", %{conn: conn} do
      conn = get(conn, "/products")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/products")
      assert redirected_to(conn) == "/"
    end

    test "renders for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/products")
      assert html_response(conn, 200) =~ "Product Management"
    end
  end

  describe "/categories access control" do
    test "redirects authenticated non-admins to /", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get("/categories")
      assert redirected_to(conn) == "/"
    end

    test "renders for admins", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get("/categories")
      assert html_response(conn, 200) =~ "Categories"
    end
  end

  describe "product list" do
    setup do
      product = product_fixture()
      %{product: product, socket: mount_live(ProductLive.Index, admin_fixture())}
    end

    test "search by SKU and the active filter narrow the list",
         %{socket: socket, product: product} do
      found = event(socket, "filter", %{"search" => product.sku})
      assert ids(found) == [product.id]
      assert html(found) =~ product.name

      assert ids(event(socket, "filter", %{"search" => product.sku, "active" => "false"})) == []

      {:ok, _} = Catalog.set_product_active(product, false)

      assert ids(event(socket, "filter", %{"search" => product.sku, "active" => "false"})) ==
               [product.id]
    end

    test "scanning a code searches for it and beeps", %{socket: socket, product: product} do
      hit = event(socket, "scan", %{"q" => product.sku})
      assert ids(hit) == [product.id]
      assert pushed_events(hit) == [{"beep", %{type: "ok"}}]

      code = "NO-SUCH-#{System.unique_integer([:positive])}"
      miss = event(socket, "scan", %{"search" => code})
      assert ids(miss) == []
      assert pushed_events(miss) == [{"beep", %{type: "error"}}]
      assert flash(miss, :error) =~ code
    end

    test "toggle_active deactivates and reactivates a product",
         %{socket: socket, product: product} do
      socket = event(socket, "toggle_active", %{"id" => product.id})
      refute Catalog.get_product!(product.id).active

      event(socket, "toggle_active", %{"id" => product.id})
      assert Catalog.get_product!(product.id).active
    end

    test "delete removes the product from the list but keeps its row for history",
         %{socket: socket, product: product} do
      socket =
        socket
        |> event("filter", %{"search" => product.sku})
        |> event("delete", %{"id" => product.id})

      assert flash(socket, :info) == "Product deleted"
      assert ids(socket) == []
      assert Zahlungs.Repo.get!(Zahlungs.Catalog.Product, product.id).deleted_at
    end

    test "the edit action loads the product into the form", %{product: product} do
      socket =
        mount_live(ProductLive.Index, admin_fixture(),
          action: :edit,
          params: %{"id" => "#{product.id}"}
        )

      assert socket.assigns.page_title == "Edit Product"
      assert socket.assigns.product.id == product.id
    end
  end
end
