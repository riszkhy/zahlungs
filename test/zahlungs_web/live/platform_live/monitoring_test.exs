defmodule ZahlungsWeb.PlatformLive.MonitoringTest do
  @moduledoc """
  The operator's monitoring page: who may open it, what its controls do (driven
  through the LiveView's callbacks, see `ZahlungsWeb.LiveDriver`) and what it
  never shows. Dev and test may share a database, so rows are found through
  organizations with a unique word in their name.
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.ServicesFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.Accounts.UserLogin
  alias Zahlungs.{Accounts, Monitoring, Repo}
  alias Zahlungs.Sales.Sale
  alias Zahlungs.Services.Transaction
  alias ZahlungsWeb.PlatformLive

  # As in DataCase: made first, so a fixture inside in_org/2 doesn't make one and
  # leave its organization as the current one.
  setup do
    default_org()
    :ok
  end

  defp word, do: "Uji#{System.unique_integer([:positive])}x"

  defp operator, do: mount_live(PlatformLive.Monitoring, superadmin_fixture())

  defp shop(name, store_attrs \\ []) do
    org = organization_fixture(name: name)

    in_org(org, fn ->
      store = store_fixture(store_attrs)
      cashier = user_fixture(store_id: store.id)
      %{org: org, store: store, cashier: cashier, shift: shift_fixture(cashier)}
    end)
  end

  defp sale!(ctx, total, at) do
    Repo.insert!(%Sale{
      store_id: ctx.store.id,
      shift_id: ctx.shift.id,
      user_id: ctx.cashier.id,
      code: "S#{System.unique_integer([:positive])}",
      total: Decimal.new(total),
      inserted_at: at,
      updated_at: at
    })
  end

  defp days_ago(days) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.add(-days * 86_400)
  end

  defp search(text, status \\ ""), do: %{"status" => status, "search" => text}

  describe "access" do
    test "guests are sent to log in", %{conn: conn} do
      assert conn |> get("/platform/monitoring") |> redirected_to() == "/users/log_in"
    end

    test "an organization's admin and a cashier are turned away", %{conn: conn} do
      {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")

      assert conn |> log_in_user(admin) |> get("/platform/monitoring") |> redirected_to() == "/"

      assert build_conn()
             |> log_in_user(user_fixture())
             |> get("/platform/monitoring")
             |> redirected_to() == "/"
    end

    test "the operator sees the page and its menu link", %{conn: conn} do
      html =
        conn
        |> log_in_user(superadmin_fixture())
        |> get("/platform/monitoring")
        |> html_response(200)

      assert html =~ "Keadaan semua organisasi"
      assert html =~ ~s(href="/platform/monitoring")
    end
  end

  describe "behaviour" do
    test "starts on active organizations and thirty days" do
      name = word()
      ctx = shop(name)
      sale!(ctx, "98765432", days_ago(10))
      organization_fixture(name: "#{name} Tangguh", status: "suspended")

      socket = operator()

      assert socket.assigns.days == 30
      assert socket.assigns.status == "active"
      assert Enum.all?(socket.assigns.visible, &(&1.organization.status == "active"))

      socket = event(socket, "filter", search(name, "active"))
      assert html(socket) =~ "Rp 98.765.432"
      refute html(socket) =~ "#{name} Tangguh"

      refute socket |> event("period", %{"days" => 7}) |> html() =~ "Rp 98.765.432"
    end

    test "period: 7 and 30 as a number or text, anything else is 30" do
      socket = operator()
      days = fn value -> event(socket, "period", %{"days" => value}).assigns.days end

      assert days.(7) == 7
      assert days.("7") == 7
      assert days.(30) == 30
      assert days.("30") == 30
      assert days.("abc") == 30
      assert days.(1) == 30
    end

    test "status, search and the quick buttons narrow the list" do
      name = word()
      unpaid = organization_fixture(name: "#{name} Belum")

      paid =
        organization_fixture(name: "#{name} Lunas", paid_until: Date.add(Date.utc_today(), 60))

      suspended = organization_fixture(name: "#{name} Henti", status: "suspended")

      socket = operator()
      all = event(socket, "filter", search(name))
      assert html(all) =~ unpaid.name
      assert html(all) =~ paid.name
      assert html(all) =~ suspended.name

      active = event(socket, "filter", search(name, "active"))
      assert html(active) =~ unpaid.name
      refute html(active) =~ suspended.name

      narrowed = event(socket, "filter", search("#{name} lun"))
      assert html(narrowed) =~ paid.name
      refute html(narrowed) =~ unpaid.name

      billing = event(all, "quick", %{"quick" => "billing"})
      assert html(billing) =~ unpaid.name
      refute html(billing) =~ paid.name

      assert all |> event("quick", %{"quick" => "problems"}) |> html() =~
               "Tidak ada organisasi yang cocok."

      assert billing |> event("quick", %{"quick" => ""}) |> html() =~ paid.name
    end

    test "changing a filter goes back to page one, and a period change doesn't" do
      name = word()
      for n <- 1..26, do: organization_fixture(name: "#{name} #{n}")

      socket = operator() |> event("filter", search(name)) |> event("page", %{"to" => 2})
      assert socket.assigns.page == 2

      assert event(socket, "filter", search(name)).assigns.page == 1
      assert event(socket, "quick", %{"quick" => "quiet"}).assigns.page == 1
      assert event(socket, "period", %{"days" => 7}).assigns.page == 2
    end

    test "a page past the end falls back to the last one that exists" do
      name = word()
      for n <- 1..26, do: organization_fixture(name: "#{name} A#{n + 100}")

      socket = operator() |> event("filter", search(name)) |> event("page", %{"to" => 2})
      assert length(socket.assigns.visible) == 1

      narrowed = event(socket, "filter", search("#{name} A126"))
      assert narrowed.assigns.page == 1
      assert html(narrowed) =~ "#{name} A126"
      refute html(narrowed) =~ "Tidak ada organisasi yang cocok."

      assert event(socket, "page", %{"to" => 99}).assigns.page == 2
    end

    test "page: a number or text, and below one or not a number is one" do
      name = word()
      for n <- 1..26, do: organization_fixture(name: "#{name} #{n}")

      socket = operator() |> event("filter", search(name))
      page = fn value -> event(socket, "page", %{"to" => value}).assigns.page end

      assert page.(2) == 2
      assert page.("2") == 2
      assert page.(0) == 1
      assert page.(-3) == 1
      assert page.("abc") == 1
    end

    test "details open and close, by a number or text, and stay open across a period change" do
      name = word()
      ctx = shop(name)

      socket = operator() |> event("filter", search(name))
      refute html(socket) =~ ctx.store.name

      socket = event(socket, "toggle", %{"id" => ctx.org.id})
      assert html(socket) =~ ctx.store.name

      socket = event(socket, "period", %{"days" => 7})
      assert html(socket) =~ ctx.store.name

      socket = event(socket, "toggle", %{"id" => to_string(ctx.org.id)})
      refute html(socket) =~ ctx.store.name
    end

    test "a store's times use that store's zone, the organization's the default one" do
      name = word()
      ctx = shop(name, utc_offset_hours: 9)
      sale!(ctx, "1000", ~N[2020-01-01 00:00:00])

      html =
        operator()
        |> event("filter", search(name))
        |> event("toggle", %{"id" => ctx.org.id})
        |> html()

      assert html =~ "01 Jan 2020 07:00"
      assert html =~ "01 Jan 2020 09:00"
    end

    test "local_time/2 reads the offset of a store's row" do
      store_row = %{utc_offset_hours: 9}

      assert Monitoring.local_time(store_row, ~N[2026-11-05 00:00:00]) == ~N[2026-11-05 09:00:00]
      assert Monitoring.local_time(store_row, nil) == nil
    end

    test "an id that isn't a number changes nothing" do
      name = word()
      organization_fixture(name: name)
      socket = operator() |> event("filter", search(name))

      assert html(event(socket, "toggle", %{"id" => "abc"})) == html(socket)
    end
  end

  describe "what the page never shows" do
    test "a customer's, cashier's or provider's details, also with details open" do
      name = word()

      org =
        organization_fixture(name: name, billing_note: "TAGIHAN-UJI", review_note: "TINJAU-UJI")

      {store, account} =
        in_org(org, fn ->
          account = api_account_fixture()
          store = assign_account(store_fixture(), account)
          cashier = user_fixture(store_id: store.id, name: "KASIR-UJI")
          shift = shift_fixture(cashier)
          product = service_product_fixture()

          Repo.insert!(%Transaction{
            store_id: store.id,
            shift_id: shift.id,
            user_id: cashier.id,
            service_product_id: product.id,
            deposit_account_id: account.id,
            code: "J#{System.unique_integer([:positive])}",
            category: "pulsa",
            product_name: "PRODUK-UJI",
            customer_ref: "089900001111",
            customer_name: "NAMA-PELANGGAN-UJI",
            customer_details: "RINCIAN-UJI",
            token_sn: "TOKEN-UJI-123",
            provider_payload: "PAYLOAD-UJI",
            provider_message: "PESAN-UJI",
            bill_reference: "REF-UJI",
            meter_reading: "METER-UJI",
            price: Decimal.new(1000),
            cost: Decimal.new(900),
            amount_paid: Decimal.new(1000),
            status: "success",
            channel: "api"
          })

          Repo.insert!(%UserLogin{
            organization_id: org.id,
            user_id: cashier.id,
            store_id: store.id,
            ip: "203.0.113.77",
            user_agent: "BROWSER-UJI",
            latitude: -7.5,
            longitude: 112.5
          })

          {store, account}
        end)

      html =
        operator()
        |> event("filter", search(name))
        |> event("toggle", %{"id" => org.id})
        |> html()

      assert html =~ store.name
      assert html =~ account.name

      for secret <- [
            "089900001111",
            "NAMA-PELANGGAN-UJI",
            "RINCIAN-UJI",
            "TOKEN-UJI-123",
            "PAYLOAD-UJI",
            "PESAN-UJI",
            "REF-UJI",
            "METER-UJI",
            "PRODUK-UJI",
            "KASIR-UJI",
            "203.0.113.77",
            "BROWSER-UJI",
            "rahasia-uji",
            "TAGIHAN-UJI",
            "TINJAU-UJI",
            account.callback_token
          ] do
        refute html =~ secret
      end
    end
  end
end
