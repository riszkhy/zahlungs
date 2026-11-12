defmodule ZahlungsWeb.ServiceHistoryLiveTest do
  @moduledoc """
  The Riwayat layanan page: access via `get/2`, the filters and pages by
  driving the LiveView's callbacks (see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Services
  alias ZahlungsWeb.ServiceLive

  @all %{
    "from" => "2000-01-01",
    "to" => "2100-01-01",
    "status" => "",
    "category" => "",
    "q" => ""
  }

  defp admin_fixture do
    {:ok, admin} = Zahlungs.Accounts.set_user_role(user_fixture(), "admin")
    admin
  end

  defp ids(socket), do: Enum.map(socket.assigns.transactions, & &1.id)

  setup do
    assign_account(default_store(), deposit_account_fixture())
    %{cashier: user_on_shift_fixture(), pulsa: service_product_fixture()}
  end

  describe "/services/history" do
    test "needs a log in", %{conn: conn} do
      assert conn |> get("/services/history") |> redirected_to() == "/users/log_in"
    end

    test "opens for a cashier and an admin", %{conn: conn, cashier: cashier} do
      assert conn |> log_in_user(cashier) |> get("/services/history") |> html_response(200) =~
               "Riwayat layanan"

      assert build_conn()
             |> log_in_user(admin_fixture())
             |> get("/services/history")
             |> html_response(200) =~ "Riwayat layanan"
    end

    test "is in the menu and on the Layanan screen", %{conn: conn, cashier: cashier} do
      assert conn |> log_in_user(cashier) |> get("/home") |> html_response(200) =~
               ~s(href="/services/history")

      assert ServiceLive.Index |> mount_live(cashier) |> html() =~ ~s(href="/services/history")
    end
  end

  describe "the list" do
    test "this month's services, a colleague's too", %{cashier: cashier, pulsa: pulsa} do
      colleague = user_on_shift_fixture(%{name: "Rekan Kerja"})
      mine = service_fixture(cashier, pulsa, %{"customer_ref" => "081234567890"})
      theirs = service_fixture(colleague, pulsa)

      socket = mount_live(ServiceLive.History, cashier)
      rendered = html(socket)

      assert ids(socket) == [theirs.id, mine.id]
      assert rendered =~ mine.code
      assert rendered =~ "0812 3456 7890"
      assert rendered =~ pulsa.name
      assert rendered =~ "Rekan Kerja"

      today = Zahlungs.LocalTime.today(default_store())
      assert socket.assigns.from == Date.to_iso8601(Date.beginning_of_month(today))
      assert socket.assigns.to == Date.to_iso8601(today)
    end

    test "says the outcome: token, reason, and a receipt only for a success", %{
      cashier: cashier,
      pulsa: pulsa
    } do
      {:ok, success} =
        Services.mark_success(service_fixture(cashier, pulsa), cashier, "SN-123456")

      {:ok, failed} =
        Services.mark_failed(service_fixture(cashier, pulsa), cashier, "Nomor salah")

      processing = service_fixture(cashier, pulsa)

      rendered = ServiceLive.History |> mount_live(cashier) |> html()

      assert rendered =~ "SN-123456"
      assert rendered =~ "Nomor salah"
      assert rendered =~ "Berhasil"
      assert rendered =~ "Gagal"
      assert rendered =~ "Diproses"
      assert rendered =~ ~s(href="/services/#{success.id}/receipt")
      refute rendered =~ ~s(href="/services/#{failed.id}/receipt")
      refute rendered =~ ~s(href="/services/#{processing.id}/receipt")
    end

    test "a token's answer shows the token alone", %{cashier: cashier} do
      token = service_product_fixture(%{category: "token_pln"})

      {:ok, _} =
        Services.mark_success(
          service_fixture(cashier, token),
          cashier,
          "1111-2222-3333-4444-5555/BUDI SANTOSO/R1M/900VA/16,9KWH"
        )

      rendered = ServiceLive.History |> mount_live(cashier) |> html()

      assert rendered =~ "1111 2222 3333 4444 5555"
      refute rendered =~ "BUDI SANTOSO"
      refute rendered =~ "16,9KWH"
    end

    test "names the store only across stores", %{cashier: cashier, pulsa: pulsa} do
      service_fixture(cashier, pulsa)
      admin = admin_fixture()

      assert ServiceLive.History |> mount_live(cashier) |> html() =~ "Kasir"
      refute ServiceLive.History |> mount_live(cashier) |> html() =~ ">Cabang<"

      assert ServiceLive.History |> mount_live(admin, store: "all") |> html() =~ ">Cabang<"
    end

    test "nothing to show says so", %{cashier: cashier} do
      assert ServiceLive.History |> mount_live(cashier) |> html() =~ "Belum ada transaksi layanan"
    end

    test "follows a service as it settles", %{cashier: cashier, pulsa: pulsa} do
      tx = service_fixture(cashier, pulsa)
      socket = mount_live(ServiceLive.History, cashier)
      refute html(socket) =~ "SN-777"

      {:ok, _} = Services.mark_success(tx, cashier, "SN-777")

      assert socket |> info({:service_changed, tx.id}) |> html() =~ "SN-777"
    end
  end

  describe "listening" do
    # An api service the provider settles later (the fake leaves digit 9 pending).
    setup %{cashier: cashier} do
      assign_account(default_store(), api_account_fixture())
      product = service_product_fixture(%{provider_code: "TSEL10"})

      {:ok, tx} =
        Services.record(cashier, product.id, %{
          "customer_ref" => "081234567899",
          "amount_paid" => "12000"
        })

      %{tx: tx}
    end

    defp settle(tx) do
      {:ok, _} = Services.apply_result(tx.id, %{status: :success, token_sn: "SN1"})
      id = tx.id
      assert_receive {:service_changed, ^id}
    end

    test "to the store's services", %{cashier: cashier, tx: tx} do
      mount_live(ServiceLive.History, cashier, connected: true)
      settle(tx)
    end

    test "to every store when all are shown", %{tx: tx} do
      mount_live(ServiceLive.History, admin_fixture(), store: "all", connected: true)
      settle(tx)
    end
  end

  describe "the filters" do
    test "each one, and the search", %{cashier: cashier, pulsa: pulsa} do
      token = service_fixture(cashier, service_product_fixture(%{category: "token_pln"}))
      {:ok, done} = Services.mark_success(service_fixture(cashier, pulsa), cashier, nil)

      socket = mount_live(ServiceLive.History, cashier)

      assert socket |> event("filter", %{@all | "status" => "success"}) |> ids() == [done.id]
      assert socket |> event("filter", %{@all | "category" => "token_pln"}) |> ids() == [token.id]
      assert socket |> event("filter", %{@all | "q" => done.code}) |> ids() == [done.id]
    end

    test "another period is empty", %{cashier: cashier, pulsa: pulsa} do
      service_fixture(cashier, pulsa)

      socket =
        ServiceLive.History
        |> mount_live(cashier)
        |> event("filter", %{@all | "from" => "2001-01-01", "to" => "2001-01-31"})

      assert ids(socket) == []
      assert html(socket) =~ "Belum ada transaksi layanan"
    end

    test "dates that aren't dates ask for valid ones", %{cashier: cashier, pulsa: pulsa} do
      service_fixture(cashier, pulsa)

      socket =
        ServiceLive.History |> mount_live(cashier) |> event("filter", %{@all | "from" => "x"})

      assert ids(socket) == []
      assert html(socket) =~ "Pilih rentang tanggal yang valid."
      refute html(socket) =~ "Belum ada transaksi layanan"
    end
  end

  describe "pages" do
    # 26 services, so page 2 holds only the oldest one.
    setup %{cashier: cashier, pulsa: pulsa} do
      %{services: for(_ <- 1..26, do: service_fixture(cashier, pulsa))}
    end

    test "25 per page, with the count", %{cashier: cashier, services: services} do
      socket = mount_live(ServiceLive.History, cashier)

      assert length(ids(socket)) == 25
      assert html(socket) =~ "Menampilkan 1–25 dari 26 transaksi"

      # JS.push sends the page as a number; a string works too.
      socket = event(socket, "page", %{"to" => 2})
      assert ids(socket) == [hd(services).id]
      assert socket |> event("page", %{"to" => "1"}) |> ids() |> length() == 25
    end

    test "a filter starts again at page 1", %{cashier: cashier} do
      socket =
        ServiceLive.History
        |> mount_live(cashier)
        |> event("page", %{"to" => 2})
        |> event("filter", %{@all | "category" => "pulsa"})

      assert socket.assigns.page == 1
    end

    test "a page past the end falls back to the last one", %{cashier: cashier} do
      socket = ServiceLive.History |> mount_live(cashier) |> event("page", %{"to" => 99})
      assert socket.assigns.page == 2
    end
  end

  describe "correcting a status" do
    setup %{cashier: cashier, pulsa: pulsa} do
      {:ok, success} = Services.mark_success(service_fixture(cashier, pulsa), cashier, "SN-1")
      %{admin: admin_fixture(), success: success}
    end

    defp status_of(tx), do: Zahlungs.Repo.reload!(tx).status

    defp corrected(socket, id, reason) do
      socket
      |> event("review_correction", %{"id" => id})
      |> event("confirm_correction", %{"reason" => reason, "token_sn" => ""})
    end

    test "an admin sees the button, a cashier doesn't", ctx do
      assert ServiceLive.History |> mount_live(ctx.admin) |> html() =~ "Koreksi status"
      refute ServiceLive.History |> mount_live(ctx.cashier) |> html() =~ "Koreksi status"
    end

    test "a cashier's event is refused", ctx do
      ServiceLive.History |> mount_live(ctx.cashier) |> corrected(ctx.success.id, "Tidak masuk")
      assert status_of(ctx.success) == "success"
    end

    test "saving needs the popup open", ctx do
      ServiceLive.History
      |> mount_live(ctx.admin)
      |> event("confirm_correction", %{"reason" => "Tidak masuk", "token_sn" => ""})

      assert status_of(ctx.success) == "success"
    end

    test "an id that isn't a service of the scope opens nothing", ctx do
      socket = mount_live(ServiceLive.History, ctx.admin)

      for id <- ["abc", "12abc", 0, ctx.success.id + 1_000_000, nil] do
        refute event(socket, "review_correction", %{"id" => id}).assigns.correcting
      end
    end

    test "Batal doesn't sit under the popup's close mark", ctx do
      html =
        ServiceLive.History
        |> mount_live(ctx.admin)
        |> event("review_correction", %{"id" => ctx.success.id})
        |> html()

      assert html =~ ~r/class="[^"]*\bpr-10\b[^"]*">\s*<h3/
    end

    defp popup_html(ctx, tx) do
      ServiceLive.History
      |> mount_live(ctx.admin)
      |> event("review_correction", %{"id" => tx.id})
      |> html()
    end

    test "the popup names its action", ctx do
      html = popup_html(ctx, ctx.success)
      assert html =~ ~r/<button[^>]*!bg-red-600[^>]*>\s*Jadikan gagal\s*<\/button>/
      refute html =~ "Simpan koreksi"
    end

    test "towards success warns the money stays", ctx do
      {:ok, failed} = Services.correct_status(ctx.admin, ctx.success, "failed", "Uji")
      html = popup_html(ctx, failed)
      assert html =~ "tidak jadi dikembalikan ke pelanggan; transaksi dihitung berhasil."
      assert html =~ ~r/<button[^>]*>\s*Jadikan berhasil\s*<\/button>/
    end

    test "Batal sits at the bottom, before the main button", ctx do
      html = popup_html(ctx, ctx.success)
      assert html =~ ~r/<\/textarea>.*phx-click="cancel_correction".*Jadikan gagal/s
      refute html =~ ~r/<\/h3>\s*<button[^>]*cancel_correction/
    end

    test "a failed service has a red badge", ctx do
      {:ok, _} = Services.correct_status(ctx.admin, ctx.success, "failed", "Uji")
      html = ServiceLive.History |> mount_live(ctx.admin) |> html()
      assert html =~ ~r/bg-red-100 text-red-700[^>]*>\s*Gagal/
    end

    test "a blank reason keeps the popup open", ctx do
      socket = ServiceLive.History |> mount_live(ctx.admin) |> corrected(ctx.success.id, "  ")

      assert socket.assigns.correcting
      assert html(socket) =~ "Alasan wajib diisi (maks. 200 karakter)."
      assert status_of(ctx.success) == "success"
    end

    test "a saved correction (id as a number)", ctx do
      socket =
        ServiceLive.History
        |> mount_live(ctx.admin)
        |> corrected(ctx.success.id, "Pulsa tidak masuk")

      assert flash(socket, :info) ==
               "Status dikoreksi menjadi Gagal. Uang menunggu dikembalikan kasir."

      refute socket.assigns.correcting
      assert html(socket) =~ "Dikoreksi"
      assert html(socket) =~ "Pulsa tidak masuk"
      assert status_of(ctx.success) == "failed"
    end

    test "a saved correction (id as text)", ctx do
      ServiceLive.History
      |> mount_live(ctx.admin)
      |> corrected("#{ctx.success.id}", "Tidak masuk")

      assert status_of(ctx.success) == "failed"
    end

    test "all stores", ctx do
      store = store_fixture()
      assign_account(store, deposit_account_fixture())
      there = user_on_shift_fixture(store_id: store.id)
      {:ok, far} = Services.mark_success(service_fixture(there, ctx.pulsa), there, "SN-2")

      ServiceLive.History
      |> mount_live(ctx.admin, store: "all")
      |> corrected(far.id, "Tidak masuk")

      assert status_of(far) == "failed"
    end

    test "a popup over a changed service", ctx do
      socket =
        ServiceLive.History
        |> mount_live(ctx.admin)
        |> event("review_correction", %{"id" => ctx.success.id})

      {:ok, _} = Services.correct_status(ctx.admin, ctx.success, "failed", "Tab lain")

      socket =
        socket
        |> info({:service_changed, ctx.success.id})
        |> event("confirm_correction", %{"reason" => "Tidak masuk", "token_sn" => ""})

      assert flash(socket, :error) == "Status transaksi sudah berubah. Muat ulang."
      assert Zahlungs.Repo.reload!(ctx.success).correction_reason == "Tab lain"
    end
  end
end
