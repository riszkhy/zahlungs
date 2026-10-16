defmodule ZahlungsWeb.ServiceProductLiveTest do
  @moduledoc """
  The admin page for PPOB service products: access via `get/2`, and the list
  and the form by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Services
  alias ZahlungsWeb.ServiceProductLive

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp ids(socket), do: Enum.map(socket.assigns.products, & &1.id)

  describe "/admin/services" do
    test "is for admins only", %{conn: conn} do
      assert conn |> log_in_user(user_fixture()) |> get("/admin/services") |> redirected_to() ==
               "/"

      assert build_conn()
             |> log_in_user(admin_fixture())
             |> get("/admin/services")
             |> html_response(200) =~
               "Produk layanan"
    end
  end

  describe "the list" do
    setup do
      %{product: service_product_fixture(), admin: admin_fixture()}
    end

    test "shows each product with its price", %{product: product, admin: admin} do
      rendered = ServiceProductLive.Index |> mount_live(admin) |> html()

      assert rendered =~ product.name
      assert rendered =~ "Rp 12.000,00"
    end

    test "filters by category", %{product: product, admin: admin} do
      token = service_product_fixture(%{category: "token_pln"})

      socket =
        ServiceProductLive.Index
        |> mount_live(admin)
        |> event("filter", %{"category" => "token_pln"})

      assert token.id in ids(socket)
      refute product.id in ids(socket)
    end

    test "deleting hides a product", %{product: product, admin: admin} do
      socket =
        ServiceProductLive.Index |> mount_live(admin) |> event("delete", %{"id" => product.id})

      assert flash(socket, :info) =~ "dihapus"
      refute product.id in ids(socket)
    end
  end

  describe "the form" do
    setup do
      %{socket: mount_live(ServiceProductLive.Index, admin_fixture(), action: :new)}
    end

    defp validate(socket, attrs), do: event(socket, "validate", %{"product" => attrs})

    @pulsa %{
      "name" => "Pulsa Telkomsel 10.000",
      "category" => "pulsa",
      "cost" => "10150",
      "margin_type" => "amount",
      "margin_value" => "1850"
    }

    test "a bill asks for the provider fee and the admin fee", %{socket: socket} do
      rendered = socket |> validate(%{@pulsa | "category" => "tagihan_pln"}) |> html()

      assert rendered =~ "Biaya penyedia"
      assert rendered =~ "Biaya admin"
    end

    test "the price preview follows the margin, in rupiah or percent", %{socket: socket} do
      assert socket |> validate(@pulsa) |> html() =~ "Rp 12.000,00"

      percent = validate(socket, %{@pulsa | "margin_type" => "percent", "margin_value" => "15"})
      assert html(percent) =~ "Rp 11.673,00"
    end

    test "saves a new product", %{socket: socket} do
      name = "Pulsa #{System.unique_integer([:positive])}"
      socket = event(socket, "save", %{"product" => %{@pulsa | "name" => name}})

      assert flash(socket, :info) =~ "disimpan"
      assert live_redirect(socket) == "/admin/services"
      assert Enum.any?(Services.list_products(), &(&1.name == name))
    end

    test "shows what is wrong instead of saving", %{socket: socket} do
      socket = event(socket, "save", %{"product" => %{@pulsa | "cost" => "0"}})

      assert html(socket) =~ "harus lebih dari 0"
      assert is_nil(live_redirect(socket))
    end

    test "edits a product" do
      product = service_product_fixture()

      socket =
        ServiceProductLive.Index
        |> mount_live(admin_fixture(), action: :edit, params: %{"id" => "#{product.id}"})
        |> event("save", %{"product" => %{"name" => "Pulsa diganti"}})

      assert flash(socket, :info) =~ "disimpan"
      assert Services.get_product!(product.id).name == "Pulsa diganti"
    end
  end
end
