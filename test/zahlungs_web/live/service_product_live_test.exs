defmodule ZahlungsWeb.ServiceProductLiveTest do
  @moduledoc """
  The admin page for PPOB service products: access via `get/2`, and the list
  and the form by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Ecto.Query

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

    test "says tagihan, not tagihan PLN, in its subtitle", %{conn: conn} do
      response =
        conn |> log_in_user(admin_fixture()) |> get("/admin/services") |> html_response(200)

      assert response =~ "Pulsa, paket data, token PLN dan tagihan (khusus admin)"
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

    test "each product is also a card with its actions, the table only on wide screens",
         %{admin: admin} do
      product = service_product_fixture(%{operator: "telkomsel"})

      Zahlungs.Repo.update_all(
        from(p in Services.Product, where: p.id == ^product.id),
        set: [provider_status: "gangguan"]
      )

      rendered =
        ServiceProductLive.Index
        |> mount_live(admin)
        |> event("filter", %{"category" => "pulsa", "operator" => "telkomsel"})
        |> html()

      assert rendered =~ ~s(class="mt-4 space-y-2 lg:hidden")
      assert rendered =~ ~s(class="hidden lg:block")

      [_, card] =
        Regex.run(~r{id="service-product-card-#{product.id}"[^>]*>(.*?)</div>}s, rendered)

      assert card =~ product.name
      assert card =~ "Telkomsel"
      assert card =~ "Modal Rp 10.150,00"
      assert card =~ "Margin Rp 1.850,00"
      assert card =~ "Rp 12.000,00"
      assert card =~ "Aktif"
      assert card =~ "Gangguan"
      assert card =~ ~s(href="/admin/services/#{product.id}/edit")
      assert card =~ "delete"
    end

    test "with no match the cards say so", %{admin: admin} do
      rendered =
        ServiceProductLive.Index
        |> mount_live(admin)
        |> event("filter", %{"category" => "tagihan"})
        |> html()

      assert rendered =~ "Tidak ada produk."
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

    test "filters by operator, and shows each product's", %{product: product, admin: admin} do
      tsel = service_product_fixture(%{operator: "telkomsel"})
      socket = mount_live(ServiceProductLive.Index, admin)

      rendered = html(socket)
      assert rendered =~ ~s(name="operator")
      assert rendered =~ "Semua operator"
      assert rendered =~ "Pulsa · Telkomsel"

      socket = event(socket, "filter", %{"category" => "", "operator" => "telkomsel"})
      assert tsel.id in ids(socket)
      refute product.id in ids(socket)

      socket = event(socket, "filter", %{"category" => "pulsa", "operator" => "other"})
      assert product.id in ids(socket)
      refute tsel.id in ids(socket)
    end

    test "token PLN and tagihan have no operator to filter by", %{admin: admin} do
      socket =
        ServiceProductLive.Index
        |> mount_live(admin)
        |> event("filter", %{"category" => "pulsa", "operator" => "telkomsel"})
        |> event("filter", %{"category" => "tagihan", "operator" => "telkomsel"})

      assert socket.assigns.operator == ""
      refute html(socket) =~ ~s(name="operator")
    end

    test "deleting hides a product", %{product: product, admin: admin} do
      socket =
        ServiceProductLive.Index |> mount_live(admin) |> event("delete", %{"id" => product.id})

      assert flash(socket, :info) =~ "dihapus"
      refute product.id in ids(socket)
    end
  end

  describe "pages" do
    # 26 products named so they sort in creation order, alone in the test's
    # organization: page 2 holds only the last one.
    setup do
      products =
        for n <- 1..26 do
          service_product_fixture(%{name: "Produk #{String.pad_leading("#{n}", 2, "0")}"})
        end

      %{products: products, admin: admin_fixture()}
    end

    test "25 products per page, with the count", %{products: products, admin: admin} do
      socket = mount_live(ServiceProductLive.Index, admin)

      assert ids(socket) == products |> Enum.take(25) |> Enum.map(& &1.id)
      assert html(socket) =~ "Menampilkan 1–25 dari 26 produk"

      # JS.push sends the page as a number; a string works too.
      socket = event(socket, "page", %{"to" => 2})
      assert ids(socket) == [List.last(products).id]
      assert html(socket) =~ "Menampilkan 26–26 dari 26 produk"

      assert socket |> event("page", %{"to" => "1"}) |> ids() |> length() == 25
    end

    test "a filter starts again at page 1", %{admin: admin} do
      socket =
        ServiceProductLive.Index
        |> mount_live(admin)
        |> event("page", %{"to" => 2})
        |> event("filter", %{"category" => "pulsa", "operator" => ""})

      assert socket.assigns.page == 1
      assert length(ids(socket)) == 25
    end

    test "deleting the last product of the last page goes back a page", %{
      products: products,
      admin: admin
    } do
      last = List.last(products)

      socket =
        ServiceProductLive.Index
        |> mount_live(admin)
        |> event("page", %{"to" => 2})
        |> event("delete", %{"id" => last.id})

      assert socket.assigns.page == 1
      assert length(ids(socket)) == 25
    end
  end

  describe "with an SBI account" do
    alias Zahlungs.Services.Provider.Sbi.StubClient

    @pricelist %{
      "PLN Prabayar" => [
        %{
          "code" => "PLN20",
          "name" => "PLN 20.000",
          "harga" => 20_775,
          "gangguan" => "Tidak",
          "tersedia" => "Ya"
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
      deposit_account_fixture(%{
        mode: "api",
        provider: "sbi",
        credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => "pw"}
      })

      %{admin: admin_fixture()}
    end

    defp field(socket, name), do: Ecto.Changeset.get_field(socket.assigns.form.source, name)

    test "a picked pulsa brings its brand", %{admin: admin} do
      StubClient.expect(
        "pricelist",
        {:ok, 200,
         %{
           "Pulsa Reguler" => [
             %{
               "code" => "T10",
               "name" => "THREE 10K",
               "category" => "THREE NASIONAL",
               "prefix" => "TRI",
               "harga" => 10_050,
               "gangguan" => "Tidak",
               "tersedia" => "Ya"
             }
           ]
         }}
      )

      socket =
        ServiceProductLive.Index
        |> mount_live(admin, action: :new)
        |> event("search_catalog", %{"q" => "three"})
        |> event("pick_catalog", %{"code" => "T10"})

      assert field(socket, :operator) == "tri"
      assert {field(socket, :category), field(socket, :provider_code)} == {"pulsa", "T10"}
    end

    test "a product is picked from SBI's price list", %{admin: admin} do
      StubClient.expect("pricelist", {:ok, 200, @pricelist})

      socket =
        ServiceProductLive.Index
        |> mount_live(admin, action: :new)
        |> event("search_catalog", %{"q" => "pln 20"})

      assert html(socket) =~ "PLN20"

      socket = event(socket, "pick_catalog", %{"code" => "PLN20"})
      assert field(socket, :provider_code) == "PLN20"
      assert field(socket, :name) == "PLN 20.000"
      assert field(socket, :category) == "token_pln"
      assert Decimal.equal?(field(socket, :cost), Decimal.new("20775"))
    end

    test "a bill shows SBI's admin and commission, and keeps the shop's extra fee", %{
      admin: admin
    } do
      StubClient.expect("pricelist", {:ok, 200, @pricelist})

      socket =
        ServiceProductLive.Index
        |> mount_live(admin, action: :new)
        |> event("search_catalog", %{"q" => "pln"})

      assert html(socket) =~ "Komisi"

      socket = event(socket, "pick_catalog", %{"code" => "PLN"})
      assert field(socket, :category) == "tagihan"
      assert html(socket) =~ "Biaya tambahan toko (akun API)"

      name = "Tagihan PLN #{System.unique_integer([:positive])}"

      event(socket, "save", %{
        "product" => %{
          "name" => name,
          "category" => "tagihan",
          "provider_code" => "PLN",
          "cost" => "0",
          "margin_type" => "amount",
          "margin_value" => "3000",
          "api_extra_fee" => "2500"
        }
      })

      bill = Enum.find(Services.list_products(), &(&1.name == name))
      assert Decimal.equal?(bill.api_extra_fee, Decimal.new("2500"))
    end

    test "prices are refreshed from SBI after a look at what changes", %{admin: admin} do
      pulsa = service_product_fixture(%{provider_code: "T10"})

      StubClient.respond("price", fn _body ->
        {:ok, 200,
         %{
           "data" => %{
             "kode" => "T10",
             "harga" => "10300",
             "gangguan" => "Tidak",
             "kosong" => "Tidak"
           }
         }}
      end)

      socket = ServiceProductLive.Index |> mount_live(admin) |> event("price_update", %{})
      rendered = html(socket)
      assert rendered =~ ~s(id="price-update")
      assert rendered =~ "Rp 10.150,00"
      assert rendered =~ "Rp 10.300,00"
      assert Decimal.equal?(Services.get_product!(pulsa.id).cost, Decimal.new("10150"))

      socket = event(socket, "apply_price_update", %{})
      assert flash(socket, :info) == "1 produk diperbarui."
      assert Decimal.equal?(Services.get_product!(pulsa.id).cost, Decimal.new("10300"))
      refute html(socket) =~ ~s(id="price-update")
    end

    test "the list shows what SBI says about each product", %{admin: admin} do
      up = service_product_fixture(%{provider_code: "T10"})
      down = service_product_fixture(%{provider_code: "T20"})

      Zahlungs.Repo.update_all(
        from(p in Services.Product, where: p.id == ^up.id),
        set: [provider_price: Decimal.new("10500")]
      )

      Zahlungs.Repo.update_all(
        from(p in Services.Product, where: p.id == ^down.id),
        set: [provider_status: "gangguan"]
      )

      rendered = ServiceProductLive.Index |> mount_live(admin) |> html()
      assert rendered =~ "Modal SBI naik"
      assert rendered =~ "Gangguan"
      assert rendered =~ "Perbarui dari SBI"
    end
  end

  test "without an SBI account there is no SBI search" do
    rendered = ServiceProductLive.Index |> mount_live(admin_fixture(), action: :new) |> html()
    refute rendered =~ "Cari di daftar SBI"
    refute rendered =~ "Perbarui dari SBI"
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
      rendered = socket |> validate(%{@pulsa | "category" => "tagihan"}) |> html()

      assert rendered =~ "Biaya penyedia"
      assert rendered =~ "Biaya admin"
    end

    test "only a bill can ask for the months", %{socket: socket} do
      refute socket |> validate(@pulsa) |> html() =~ "Tanyakan jumlah bulan saat cek tagihan"

      assert socket |> validate(%{@pulsa | "category" => "tagihan"}) |> html() =~
               "Tanyakan jumlah bulan saat cek tagihan"
    end

    test "a bill keeps whether it asks for the months", %{socket: socket} do
      name = "BPJS #{System.unique_integer([:positive])}"
      bill = %{@pulsa | "category" => "tagihan", "name" => name}

      event(socket, "save", %{"product" => Map.put(bill, "ask_months", "true")})
      assert Enum.find(Services.list_products(), &(&1.name == name)).ask_months

      other = "Tagihan #{System.unique_integer([:positive])}"
      event(socket, "save", %{"product" => %{bill | "name" => other}})
      refute Enum.find(Services.list_products(), &(&1.name == other)).ask_months
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

    test "a token PLN may be sold without the owner check", %{socket: socket} do
      token = %{@pulsa | "category" => "token_pln"}
      refute socket |> validate(@pulsa) |> html() =~ "Cek pelanggan dulu"
      assert socket |> validate(token) |> html() =~ "Cek pelanggan dulu"

      name = "Token #{System.unique_integer([:positive])}"

      event(socket, "save", %{
        "product" => Map.merge(token, %{"name" => name, "owner_check" => "false"})
      })

      refute Enum.find(Services.list_products(), &(&1.name == name)).owner_check
    end

    test "a token PLN keeps its owner-check code; other categories don't ask", %{socket: socket} do
      refute socket |> validate(@pulsa) |> html() =~ "Kode cek pelanggan"

      token = %{@pulsa | "category" => "token_pln"}
      assert socket |> validate(token) |> html() =~ "Kode cek pelanggan"

      name = "Token #{System.unique_integer([:positive])}"

      event(socket, "save", %{
        "product" =>
          Map.merge(token, %{
            "name" => name,
            "provider_code" => "PLN20",
            "provider_check_code" => "CEKPLN"
          })
      })

      saved = Enum.find(Services.list_products(), &(&1.name == name))
      assert {saved.provider_code, saved.provider_check_code} == {"PLN20", "CEKPLN"}
    end

    test "pulsa and paket data pick their operator from the brands", %{socket: socket} do
      rendered = socket |> validate(@pulsa) |> html()
      assert rendered =~ ~s(name="product[operator]")
      assert rendered =~ "Telkomsel"
      assert rendered =~ "Smartfren"

      refute socket |> validate(%{@pulsa | "category" => "tagihan"}) |> html() =~
               ~s(name="product[operator]")

      name = "Pulsa #{System.unique_integer([:positive])}"

      event(socket, "save", %{
        "product" => Map.merge(@pulsa, %{"name" => name, "operator" => "indosat"})
      })

      assert Enum.find(Services.list_products(), &(&1.name == name)).operator == "indosat"
    end

    test "picks how the price is rounded", %{socket: socket} do
      rendered = html(socket)
      assert rendered =~ ~s(name="product[price_rounding]")
      assert rendered =~ "Ke atas 1.000"

      name = "Pulsa #{System.unique_integer([:positive])}"

      event(socket, "save", %{
        "product" => Map.merge(@pulsa, %{"name" => name, "price_rounding" => "500"})
      })

      assert Enum.find(Services.list_products(), &(&1.name == name)).price_rounding == 500
    end

    test "keeps the vendor's product code", %{socket: socket} do
      name = "Pulsa #{System.unique_integer([:positive])}"
      assert html(socket) =~ "Kode produk vendor"

      event(socket, "save", %{
        "product" => Map.merge(@pulsa, %{"name" => name, "provider_code" => "TSEL10"})
      })

      assert Enum.find(Services.list_products(), &(&1.name == name)).provider_code == "TSEL10"
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

  describe "export" do
    test "the Export Excel link follows the filters" do
      socket = ServiceProductLive.Index |> mount_live(admin_fixture())
      assert html(socket) =~ ~s(href="/admin/services/export.xlsx?category=&amp;operator=")

      socket = event(socket, "filter", %{"category" => "pulsa", "operator" => "telkomsel"})

      assert html(socket) =~
               ~s(href="/admin/services/export.xlsx?category=pulsa&amp;operator=telkomsel")
    end
  end
end
