defmodule ZahlungsWeb.ServiceLiveTest do
  @moduledoc """
  The cashier's Layanan screen: access via `get/2`, and recording and marking
  services by driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.ServicesFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Services, Shifts}
  alias ZahlungsWeb.ServiceLive

  defp money(value), do: Decimal.new(value)

  describe "/services" do
    test "redirects guests to the log in page", %{conn: conn} do
      assert conn |> get("/services") |> redirected_to() == "/users/log_in"
    end

    test "renders for a cashier", %{conn: conn} do
      assert conn |> log_in_user(user_fixture()) |> get("/services") |> html_response(200) =~
               "Layanan"
    end

    test "says tagihan, not tagihan PLN, in its subtitle", %{conn: conn} do
      response = conn |> log_in_user(user_fixture()) |> get("/services") |> html_response(200)

      assert response =~ "Pulsa, paket data, token PLN dan tagihan"
    end
  end

  describe "before selling" do
    test "without a shift it sends the cashier to open one" do
      rendered = ServiceLive.Index |> mount_live(user_fixture()) |> html()

      assert rendered =~ ~s(href="/cashier")
      refute rendered =~ "Catat dan terima uang"
    end

    test "without a deposit account it says the admin must set one up" do
      rendered = ServiceLive.Index |> mount_live(user_on_shift_fixture()) |> html()

      assert rendered =~ "belum punya akun deposit aktif"
      refute rendered =~ "Catat dan terima uang"
    end
  end

  describe "selling" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      cashier = user_on_shift_fixture()
      product = service_product_fixture()

      %{
        cashier: cashier,
        product: product,
        shift: Shifts.current_shift(cashier),
        socket:
          ServiceLive.Index
          |> mount_live(cashier)
          |> event("set_category", %{"category" => "pulsa"})
      }
    end

    defp sell(socket, product, form) do
      socket
      |> event("select", %{"id" => product.id})
      |> event("record", %{"service" => form})
    end

    test "records a service and lists it as processing", ctx do
      socket =
        sell(ctx.socket, ctx.product, %{
          "customer_ref" => "0812-3456-7890",
          "payment_method" => "cash",
          "amount_paid" => "20.000"
        })

      assert flash(socket, :info) =~ "Dicatat"
      assert html(socket) =~ "0812 3456 7890"

      assert [tx] = Services.list_shift_transactions(ctx.shift)
      assert tx.status == "processing"
      assert Decimal.equal?(tx.amount_paid, money("20000"))
      assert Decimal.equal?(tx.change_due, money("8000"))
    end

    test "tagihan PLN reads the bill with thousand separators", ctx do
      bill =
        service_product_fixture(%{category: "tagihan", cost: "1500", margin_value: "3000"})

      socket =
        ctx.socket
        |> event("set_category", %{"category" => "tagihan"})
        |> sell(bill, %{
          "customer_ref" => "530011223344",
          "bill_amount" => "245.000",
          "payment_method" => "cash",
          "amount_paid" => "250.000"
        })

      assert flash(socket, :info) =~ "Dicatat"
      assert [tx] = Services.list_shift_transactions(ctx.shift)
      assert Decimal.equal?(tx.bill_amount, money("245000"))
      assert Decimal.equal?(tx.price, money("248000"))
    end

    test "previews the price and the change while the form is filled in", ctx do
      socket =
        ctx.socket
        |> event("select", %{"id" => "#{ctx.product.id}"})
        |> event("change", %{
          "service" => %{
            "customer_ref" => "0812",
            "payment_method" => "cash",
            "amount_paid" => "20.000"
          }
        })

      rendered = html(socket)
      assert rendered =~ "Rp 12.000"
      assert rendered =~ "Rp 8.000"
    end

    test "says what went wrong", ctx do
      no_product =
        event(ctx.socket, "record", %{"service" => %{"customer_ref" => "081234567890"}})

      assert flash(no_product, :error) == "Pilih produk dulu."

      short =
        sell(ctx.socket, ctx.product, %{
          "customer_ref" => "081234567890",
          "payment_method" => "cash",
          "amount_paid" => "10.000"
        })

      assert flash(short, :error) == "Uang diterima kurang dari harga."

      bad_number =
        sell(ctx.socket, ctx.product, %{
          "customer_ref" => "12",
          "payment_method" => "cash",
          "amount_paid" => "20.000"
        })

      assert flash(bad_number, :error) == "Nomor tujuan harus 6–20 angka."
      assert Services.list_shift_transactions(ctx.shift) == []
    end

    test "marking success keeps the token; failing tells how much to return", ctx do
      done = service_fixture(ctx.cashier, ctx.product)
      failed = service_fixture(ctx.cashier, ctx.product)

      socket =
        event(ctx.socket, "mark_success", %{
          "transaction_id" => done.id,
          "token_sn" => "5821 0344 9917 2268 4410"
        })

      assert flash(socket, :info) =~ "Berhasil"

      assert Services.get_transaction!(store_scope(), done.id).token_sn ==
               "5821 0344 9917 2268 4410"

      socket =
        event(socket, "mark_failed", %{
          "transaction_id" => "#{failed.id}",
          "reason" => "nomor tidak aktif"
        })

      assert flash(socket, :info) == "Kembalikan Rp 12.000 ke pelanggan."
      assert Services.get_transaction!(store_scope(), failed.id).status == "failed"

      again = event(socket, "mark_failed", %{"transaction_id" => failed.id, "reason" => "lagi"})
      assert flash(again, :error) == "Transaksi ini sudah ditandai."
    end

    test "a successful service links to its receipt; one still processing doesn't", ctx do
      done = service_fixture(ctx.cashier, ctx.product)
      waiting = service_fixture(ctx.cashier, ctx.product)

      rendered =
        ctx.socket
        |> event("mark_success", %{"transaction_id" => done.id, "token_sn" => ""})
        |> html()

      assert rendered =~ ~s(href="/services/#{done.id}/receipt")
      refute rendered =~ ~s(href="/services/#{waiting.id}/receipt")
    end

    test "a price changed since the screen opened is not charged silently", ctx do
      socket = event(ctx.socket, "select", %{"id" => ctx.product.id})
      {:ok, _} = Services.update_product(ctx.product, %{margin_value: "2850"})

      socket =
        event(socket, "record", %{
          "service" => %{
            "customer_ref" => "081234567890",
            "payment_method" => "cash",
            "amount_paid" => "20.000"
          }
        })

      assert flash(socket, :error) =~ "berubah"
      assert flash(socket, :error) =~ "Rp 13.000"
      assert Services.list_shift_transactions(ctx.shift) == []
      assert html(socket) =~ "Rp 13.000"
    end

    test "a failed non-cash service is refunded outside the drawer", ctx do
      qris = service_fixture(ctx.cashier, ctx.product, %{"payment_method" => "qris"})

      socket =
        event(ctx.socket, "mark_failed", %{"transaction_id" => qris.id, "reason" => "gagal"})

      assert flash(socket, :info) ==
               "Kembalikan Rp 12.000 ke pelanggan lewat QRIS, bukan dari laci."
    end

    test "amounts typed with a decimal comma keep their size", ctx do
      bill =
        service_product_fixture(%{category: "tagihan", cost: "1500", margin_value: "3000"})

      socket =
        ctx.socket
        |> event("set_category", %{"category" => "tagihan"})
        |> sell(bill, %{
          "customer_ref" => "530011223344",
          "bill_amount" => "245.000,00",
          "payment_method" => "qris"
        })

      assert flash(socket, :info) =~ "Dicatat"
      assert [tx] = Services.list_shift_transactions(ctx.shift)
      assert Decimal.equal?(tx.bill_amount, money("245000"))
    end

    test "the record button can't be pressed twice", ctx do
      rendered = ctx.socket |> event("select", %{"id" => ctx.product.id}) |> html()

      assert [button] = Regex.run(~r{<button[^>]*>\s*Catat dan terima uang\s*</button>}, rendered)
      assert button =~ "phx-disable-with"
    end
  end

  describe "brands on pulsa and paket data" do
    setup do
      assign_account(default_store(), deposit_account_fixture())
      cashier = user_on_shift_fixture()

      %{
        cashier: cashier,
        shift: Shifts.current_shift(cashier),
        tsel:
          service_product_fixture(%{
            name: "Simpati 10 #{System.unique_integer([:positive])}",
            operator: "telkomsel"
          }),
        isat:
          service_product_fixture(%{
            name: "IM3 10 #{System.unique_integer([:positive])}",
            operator: "indosat"
          }),
        other: service_product_fixture(%{name: "Lain 10 #{System.unique_integer([:positive])}"}),
        socket:
          ServiceLive.Index
          |> mount_live(cashier)
          |> event("set_category", %{"category" => "pulsa"})
      }
    end

    defp typed(socket, number),
      do: event(socket, "change", %{"service" => %{"customer_ref" => number}})

    test "the number comes first, with the brands that have products", ctx do
      rendered = html(ctx.socket)
      assert rendered =~ ~s(id="brand-number")
      assert rendered =~ "Semua"
      assert rendered =~ "Telkomsel"
      assert rendered =~ "Indosat"
      assert rendered =~ "Lainnya"
      refute rendered =~ ">Smartfren<"
      assert rendered =~ ctx.tsel.name and rendered =~ ctx.isat.name
    end

    test "typing the number picks its brand and shows only its products", ctx do
      socket = typed(ctx.socket, "0812")
      assert socket.assigns.brand == "telkomsel"
      rendered = html(socket)
      assert rendered =~ ctx.tsel.name
      refute rendered =~ ctx.isat.name
      refute rendered =~ ctx.other.name

      assert typed(socket, "0857 1234").assigns.brand == "indosat"
      # Too short, or no brand: the choice stays.
      assert typed(socket, "021").assigns.brand == "telkomsel"
    end

    test "a brand can be picked by hand, and Semua shows everything", ctx do
      socket = ctx.socket |> typed("081234567890") |> event("set_brand", %{"brand" => "indosat"})
      assert html(socket) =~ ctx.isat.name
      refute html(socket) =~ ctx.tsel.name

      socket = event(socket, "set_brand", %{"brand" => ""})
      assert html(socket) =~ ctx.tsel.name and html(socket) =~ ctx.isat.name

      socket = event(socket, "set_brand", %{"brand" => "other"})
      assert html(socket) =~ ctx.other.name
      refute html(socket) =~ ctx.tsel.name
    end

    test "the number typed first is the one sold", ctx do
      socket =
        ctx.socket
        |> typed("0812-3456-7890")
        |> event("select", %{"id" => ctx.tsel.id})
        |> event("record", %{
          "service" => %{"payment_method" => "cash", "amount_paid" => "12.000"}
        })

      assert flash(socket, :info)
      assert [%{customer_ref: "081234567890"}] = Services.list_shift_transactions(ctx.shift)
    end

    test "a number of another brand lets the selected product go", ctx do
      socket = ctx.socket |> event("select", %{"id" => ctx.tsel.id}) |> typed("0857")
      assert socket.assigns.selected == nil

      socket = ctx.socket |> event("select", %{"id" => ctx.other.id}) |> typed("0857")
      assert socket.assigns.selected.id == ctx.other.id
    end

    test "a number of a brand without products keeps every product", ctx do
      socket = ctx.socket |> typed("0812") |> typed("0895 1234")
      assert socket.assigns.brand == nil
      rendered = html(socket)

      assert rendered =~ ctx.tsel.name and rendered =~ ctx.isat.name and
               rendered =~ ctx.other.name
    end

    test "a brand with nothing to show says so, with a way back", ctx do
      rendered = ctx.socket |> event("set_brand", %{"brand" => "smartfren"}) |> html()
      assert rendered =~ "Belum ada produk Smartfren."
      assert rendered =~ "Tampilkan semua"
    end

    test "the number is read back under the field, with its brand", ctx do
      rendered = ctx.socket |> typed("081234567890") |> html()
      assert rendered =~ "Telkomsel · 0812 3456 7890"
      assert rendered =~ ~s(placeholder="08xx xxxx xxxx")
    end

    test "the number can be cleared at once", ctx do
      socket = ctx.socket |> typed("081234567890") |> event("clear_number")
      assert socket.assigns.form["customer_ref"] == ""
      assert socket.assigns.brand == nil
    end

    test "the panel asks for the number first", ctx do
      assert html(ctx.socket) =~ "Isi nomor tujuan, lalu pilih produk."

      assert ctx.socket |> event("set_category", %{"category" => "tagihan"}) |> html() =~
               "Pilih produk di kiri."
    end

    test "brand chips are smaller than the category ones", ctx do
      rendered = html(ctx.socket)
      assert rendered =~ ~r/class="chip chip-sm[^"]*"[^>]*>\s*Semua/
    end

    test "another category forgets the brand", ctx do
      socket = ctx.socket |> typed("0812") |> event("set_category", %{"category" => "tagihan"})
      assert socket.assigns.brand == nil
      refute html(socket) =~ ~s(id="brand-number")
    end
  end

  describe "group_digits/1" do
    test "groups a number in fours from the left" do
      assert ServiceLive.Index.group_digits("081234567890") == "0812 3456 7890"
      assert ServiceLive.Index.group_digits("6281234567890") == "6281 2345 6789 0"
      assert ServiceLive.Index.group_digits("") == ""
    end
  end

  describe "a bill that asks how many months" do
    alias Zahlungs.Services.Provider.Sbi.StubClient

    setup do
      assign_account(
        default_store(),
        deposit_account_fixture(%{
          mode: "api",
          provider: "sbi",
          credentials: %{"member_id" => "MM1", "pin" => "1234", "password" => "pw"}
        })
      )

      cashier = user_on_shift_fixture()

      bpjs =
        api_product_fixture(%{ask_months: true, provider_code: "BPJSKS", api_extra_fee: "1000"})

      %{
        cashier: cashier,
        bpjs: bpjs,
        shift: Shifts.current_shift(cashier),
        socket:
          ServiceLive.Index
          |> mount_live(cashier)
          |> event("set_category", %{"category" => "tagihan"})
          |> event("select", %{"id" => bpjs.id})
      }
    end

    defp queue_inquiry do
      StubClient.expect(
        "inquiry",
        {:ok, 200,
         %{
           "data" => %{
             "status" => 1,
             "ref_2" => "S1",
             "price" => "567000",
             "total_payment" => "570000",
             "msg" => "SUKSES"
           }
         }}
      )
    end

    defp inquire(socket, months) do
      event(socket, "inquire", %{
        "service" => %{"customer_ref" => "8888803136606896", "months" => months}
      })
    end

    test "the check form has a months choice from 1 to 12", ctx do
      rendered = html(ctx.socket)

      assert rendered =~ "Jumlah bulan"
      assert rendered =~ ~s(name="service[months]")
      assert rendered =~ ~s(<option value="12")
      refute rendered =~ ~s(<option value="13")
      assert rendered =~ ~r/<option value="1" selected/
    end

    test "a bill that doesn't ask has no months choice", ctx do
      plain = api_product_fixture(%{provider_code: "PLNPASCA"})

      rendered =
        ctx.socket
        |> event("set_category", %{"category" => "tagihan"})
        |> event("select", %{"id" => plain.id})
        |> html()

      assert rendered =~ "Cek tagihan"
      refute rendered =~ "Jumlah bulan"
      refute rendered =~ ~s(name="service[months]")
    end

    test "a manual account asks nothing", ctx do
      assign_account(default_store(), deposit_account_fixture())

      rendered =
        ServiceLive.Index
        |> mount_live(ctx.cashier)
        |> event("set_category", %{"category" => "tagihan"})
        |> event("select", %{"id" => ctx.bpjs.id})
        |> html()

      refute rendered =~ "Jumlah bulan"
      refute rendered =~ ~s(name="service[months]")
    end

    test "the months chosen are checked and shown on the card", ctx do
      queue_inquiry()
      socket = inquire(ctx.socket, "3")
      rendered = html(socket)

      assert socket.assigns.inquiry.months == 3
      assert rendered =~ "3 bulan"
      assert rendered =~ "Rp 573.000"
      assert [{"inquiry", %{"periode" => "3"}, _}] = StubClient.requests()
    end

    test "other months are refused with a message", ctx do
      socket = inquire(ctx.socket, "13")

      assert flash(socket, :error) == "Jumlah bulan harus 1–12."
      assert is_nil(socket.assigns.inquiry)
      assert StubClient.requests() == []
    end

    test "a bill for other months than asked is refused with a message", ctx do
      StubClient.expect(
        "inquiry",
        {:ok, 200,
         %{
           "data" => %{
             "status" => 1,
             "ref_2" => "S1",
             "price" => "378000",
             "total_payment" => "380000",
             "msg" => "SUKSES CEK TAGIHAN @DATA: Nama:BUDI/Jml bulan:2/Blth:JUL 24, AGU 24"
           }
         }}
      )

      socket = inquire(ctx.socket, "3")

      assert flash(socket, :error) =~ "Penyedia menagih 2 bulan"
      assert is_nil(socket.assigns.inquiry)
    end

    test "changing the months after checking drops the result", ctx do
      queue_inquiry()

      socket =
        ctx.socket
        |> inquire("3")
        |> event("change", %{"service" => %{"months" => "2"}})

      assert is_nil(socket.assigns.inquiry)
      assert is_nil(socket.assigns.preview)
      refute html(socket) =~ ~s(phx-submit="record")
    end

    test "the same months keep the result", ctx do
      queue_inquiry()

      socket =
        ctx.socket
        |> inquire("3")
        |> event("change", %{"service" => %{"months" => "3", "payment_method" => "qris"}})

      assert socket.assigns.inquiry.months == 3
    end

    test "months don't touch the result of a bill that doesn't ask", ctx do
      api_store_fixture()
      plain = api_product_fixture()

      socket =
        ServiceLive.Index
        |> mount_live(ctx.cashier)
        |> event("set_category", %{"category" => "tagihan"})
        |> event("select", %{"id" => plain.id})
        |> event("inquire", %{"service" => %{"customer_ref" => "530011223331", "months" => "1"}})
        |> event("change", %{"service" => %{"months" => "2"}})

      assert %{months: nil} = socket.assigns.inquiry
    end

    test "paying clears the form, months included", ctx do
      queue_inquiry()

      StubClient.expect(
        "payment",
        {:ok, 200, %{"data" => %{"status" => 2, "ref_2" => "S1", "msg" => "PROSES"}}}
      )

      socket =
        ctx.socket
        |> inquire("3")
        |> event("record", %{
          "service" => %{"payment_method" => "cash", "amount_paid" => "573.000"}
        })

      assert flash(socket, :info) =~ "penyedia"
      assert socket.assigns.form["months"] == "1"
      assert is_nil(socket.assigns.inquiry)
      assert [%{sheets: 3}] = Services.list_shift_transactions(ctx.shift)
    end
  end

  describe "an api account" do
    setup do
      api_store_fixture()
      cashier = user_on_shift_fixture()

      %{
        cashier: cashier,
        shift: Shifts.current_shift(cashier),
        bill: api_product_fixture(),
        pulsa: service_product_fixture(%{provider_code: "TSEL10"}),
        socket: mount_live(ServiceLive.Index, cashier)
      }
    end

    defp checked(socket, bill, number) do
      socket
      |> event("set_category", %{"category" => "tagihan"})
      |> event("select", %{"id" => bill.id})
      |> event("inquire", %{"service" => %{"customer_ref" => number}})
    end

    defp sell_pulsa(socket, pulsa, number) do
      socket
      |> event("set_category", %{"category" => "pulsa"})
      |> event("select", %{"id" => pulsa.id})
      |> event("record", %{
        "service" => %{
          "customer_ref" => number,
          "payment_method" => "cash",
          "amount_paid" => "12.000"
        }
      })
    end

    test "a token without the owner check is sold like pulsa", ctx do
      token =
        service_product_fixture(%{
          category: "token_pln",
          provider_code: "PLN20",
          cost: "20775",
          margin_value: "1225",
          owner_check: false
        })

      socket =
        ctx.socket
        |> event("set_category", %{"category" => "token_pln"})
        |> event("select", %{"id" => token.id})

      rendered = html(socket)
      refute rendered =~ "Cek pelanggan"
      assert rendered =~ ~s(phx-submit="record")

      socket =
        event(socket, "record", %{
          "service" => %{
            "customer_ref" => "14123344441",
            "payment_method" => "cash",
            "amount_paid" => "22.000"
          }
        })

      assert flash(socket, :info) =~ "penyedia"

      assert [%{status: "success", customer_ref: "14123344441"}] =
               Services.list_shift_transactions(ctx.shift)
    end

    test "a token is bought after checking the meter's owner", ctx do
      token =
        service_product_fixture(%{
          category: "token_pln",
          provider_code: "PLN20",
          cost: "20775",
          margin_value: "1225"
        })

      socket =
        ctx.socket
        |> event("set_category", %{"category" => "token_pln"})
        |> event("select", %{"id" => token.id})

      assert html(socket) =~ "Cek pelanggan"
      refute html(socket) =~ ~s(phx-submit="record")

      socket = event(socket, "inquire", %{"service" => %{"customer_ref" => "1412-3344-441"}})
      rendered = html(socket)
      assert rendered =~ "PELANGGAN 4441"
      assert rendered =~ "R1/900VA"
      assert rendered =~ "Rp 22.000"
      assert rendered =~ ~s(phx-submit="record")

      socket =
        event(socket, "record", %{
          "service" => %{"payment_method" => "cash", "amount_paid" => "22.000"}
        })

      assert flash(socket, :info) =~ "penyedia"
      assert [tx] = Services.list_shift_transactions(ctx.shift)

      assert {tx.status, tx.customer_ref, tx.customer_details} ==
               {"success", "14123344441", "R1/900VA"}
    end

    test "a bill shows the provider's admin and the shop's extra fee", ctx do
      rendered = ctx.socket |> checked(ctx.bill, "530011223331") |> html()
      assert rendered =~ "Admin penyedia"
      assert rendered =~ "Tambahan toko"
      assert rendered =~ "Rp 9.000"
      assert rendered =~ "Rp 744.000"
    end

    test "a service held for review says so", ctx do
      {:ok, tx} =
        Services.record(ctx.cashier, ctx.pulsa.id, %{
          "customer_ref" => "081234567891",
          "amount_paid" => "12000"
        })

      {:ok, _} = Services.apply_result(tx.id, %{status: :refunded, message: "Refund transaksi"})

      {:ok, _} =
        Services.apply_result(tx.id, %{status: :success, token_sn: "SN", provider_ref: "R"})

      rendered = ServiceLive.Index |> mount_live(ctx.cashier) |> html()
      assert rendered =~ "Perlu ditinjau"
    end

    test "a bill is checked, shown, then paid", ctx do
      socket = checked(ctx.socket, ctx.bill, "5300 1122 3331")
      rendered = html(socket)

      assert rendered =~ "PELANGGAN 3331"
      assert rendered =~ "AGU–OKT 2026"
      assert rendered =~ "3 bulan"
      assert rendered =~ "Rp 744.000"

      socket =
        event(socket, "record", %{
          "service" => %{"payment_method" => "cash", "amount_paid" => "750.000"}
        })

      assert flash(socket, :info) =~ "penyedia"
      assert [tx] = Services.list_shift_transactions(ctx.shift)
      assert {tx.channel, tx.status, tx.customer_ref} == {"api", "success", "530011223331"}
      assert Decimal.equal?(tx.change_due, money("6000"))
      assert is_nil(socket.assigns.inquiry)
    end

    test "changing the number after checking drops the result", ctx do
      socket =
        ctx.socket
        |> checked(ctx.bill, "530011223331")
        |> event("change", %{"service" => %{"customer_ref" => "530011223341"}})

      assert is_nil(socket.assigns.inquiry)
      refute html(socket) =~ "PELANGGAN 3331"
      refute html(socket) =~ ~s(phx-submit="record")
    end

    test "a slow or refusing provider says so", ctx do
      assert ctx.socket |> checked(ctx.bill, "530011223347") |> flash(:error) ==
               "Penyedia tidak tersedia, coba lagi."

      assert ctx.socket |> checked(ctx.bill, "530011223345") |> flash(:error) ==
               "Tagihan ini sudah lunas."

      assert Services.list_shift_transactions(ctx.shift) == []
    end

    test "pending shows the wait and a status check", ctx do
      socket = sell_pulsa(ctx.socket, ctx.pulsa, "081234567899")
      rendered = html(socket)

      assert rendered =~ "Menunggu penyedia"
      refute rendered =~ ~s(phx-submit="mark_success")
      assert [tx] = socket.assigns.processing

      socket = event(socket, "check_status", %{"transaction_id" => tx.id})
      assert flash(socket, :info) =~ "Berhasil"
      assert socket.assigns.processing == []
    end

    test "refunds due are confirmed from the screen", ctx do
      {:ok, tx} =
        Services.record(ctx.cashier, ctx.pulsa.id, %{
          "customer_ref" => "081234567898",
          "amount_paid" => "12000"
        })

      {:ok, _} = Shifts.close_shift(ctx.shift, "12000")
      Services.check_pending(NaiveDateTime.add(NaiveDateTime.utc_now(), 61))
      shift_fixture(ctx.cashier, "0")

      socket = mount_live(ServiceLive.Index, ctx.cashier)
      assert html(socket) =~ "Perlu dikembalikan"

      socket = event(socket, "confirm_refund", %{"transaction_id" => "#{tx.id}"})
      assert flash(socket, :info) =~ "Pengembalian dicatat"
      assert socket.assigns.refunds == []
    end

    test "an admin may mark a service the provider has left waiting", ctx do
      {:ok, admin} = Zahlungs.Accounts.set_user_role(user_on_shift_fixture(), "admin")

      {:ok, tx} =
        Services.record(admin, ctx.pulsa.id, %{
          "customer_ref" => "081234567894",
          "amount_paid" => "12000"
        })

      refute ServiceLive.Index |> mount_live(admin) |> html() =~ ~s(phx-submit="mark_failed")

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -11 * 60, :second)

      tx
      |> Ecto.Changeset.change(inserted_at: NaiveDateTime.truncate(long_ago, :second))
      |> Zahlungs.Repo.update!()

      rendered = ServiceLive.Index |> mount_live(admin) |> html()
      assert rendered =~ ~s(phx-submit="mark_failed")
      assert rendered =~ "Periksa di aplikasi penyedia, lalu tandai"
    end

    test "updates arrive by themselves", ctx do
      socket = mount_live(ServiceLive.Index, ctx.cashier, connected: true)

      {:ok, tx} =
        Services.record(ctx.cashier, ctx.pulsa.id, %{
          "customer_ref" => "081234567899",
          "amount_paid" => "12000"
        })

      id = tx.id
      assert_receive {:service_changed, ^id}
      Services.check_pending(NaiveDateTime.add(NaiveDateTime.utc_now(), 31))
      assert_receive {:service_changed, ^id}

      socket = info(socket, {:service_changed, id})
      assert socket.assigns.processing == []
      assert [%{status: "success"}] = socket.assigns.history
    end
  end
end
