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
        service_product_fixture(%{category: "tagihan_pln", cost: "1500", margin_value: "3000"})

      socket =
        ctx.socket
        |> event("set_category", %{"category" => "tagihan_pln"})
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
      assert rendered =~ "Rp 12.000,00"
      assert rendered =~ "Rp 8.000,00"
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

      assert flash(socket, :info) == "Kembalikan Rp 12.000,00 ke pelanggan."
      assert Services.get_transaction!(store_scope(), failed.id).status == "failed"

      again = event(socket, "mark_failed", %{"transaction_id" => failed.id, "reason" => "lagi"})
      assert flash(again, :error) == "Transaksi ini sudah ditandai."
    end

    test "the record button can't be pressed twice", ctx do
      rendered = ctx.socket |> event("select", %{"id" => ctx.product.id}) |> html()

      assert [button] = Regex.run(~r{<button[^>]*>\s*Catat dan terima uang\s*</button>}, rendered)
      assert button =~ "phx-disable-with"
    end
  end

  describe "group_digits/1" do
    test "groups a number in fours from the left" do
      assert ServiceLive.Index.group_digits("081234567890") == "0812 3456 7890"
      assert ServiceLive.Index.group_digits("6281234567890") == "6281 2345 6789 0"
      assert ServiceLive.Index.group_digits("") == ""
    end
  end
end
