defmodule ZahlungsWeb.PlatformLiveTest do
  @moduledoc """
  The platform operator's pages: who may open them, and reviewing organizations
  (driven through the LiveView's callbacks, see `ZahlungsWeb.LiveDriver`).
  """
  use ZahlungsWeb.ConnCase, async: true

  import Zahlungs.AccountsFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Accounts, Organizations}
  alias ZahlungsWeb.PlatformLive

  defp pending_org do
    {:ok, %{organization: org, owner: owner}} =
      Organizations.register(%{
        "business_name" => "Toko Tinjau #{System.unique_integer([:positive])}",
        "name" => "Pemilik",
        "email" => unique_user_email(),
        "password" => "rahasia-sekali-123"
      })

    %{org: org, owner: owner}
  end

  defp status(org), do: Organizations.get_organization!(org.id).status

  describe "access" do
    test "guests are sent to log in", %{conn: conn} do
      assert conn |> get("/platform/organizations") |> redirected_to() == "/users/log_in"
    end

    test "an organization's admin is not a platform admin", %{conn: conn} do
      {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")

      assert conn |> log_in_user(admin) |> get("/platform/organizations") |> redirected_to() ==
               "/"
    end

    test "the operator sees the organizations and nothing of the point of sale", %{conn: conn} do
      %{org: org, owner: owner} = pending_org()
      conn = log_in_user(conn, superadmin_fixture())

      response = conn |> get("/platform/organizations") |> html_response(200)

      assert response =~ "Organisasi"
      assert response =~ org.name
      assert response =~ owner.email
      refute response =~ ~s(href="/cashier")

      # The point of sale needs an organization: the operator is sent back.
      assert conn |> get("/home") |> redirected_to() == "/platform/organizations"
      assert conn |> get("/admin/users") |> redirected_to() == "/platform/organizations"
    end

    test "the operator lands on the platform page after logging in", %{conn: conn} do
      operator = superadmin_fixture()

      conn =
        post(conn, "/users/log_in", %{
          "user" => %{"email" => operator.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/platform/organizations"
    end
  end

  describe "reviewing" do
    setup do
      Map.put(pending_org(), :operator, superadmin_fixture())
    end

    test "lists every organization with its owner, and filters by status", ctx do
      socket = mount_live(PlatformLive.Organizations, ctx.operator)

      row = Enum.find(socket.assigns.rows, &(&1.organization.id == ctx.org.id))
      assert {row.owner_email, row.organization.status} == {ctx.owner.email, "pending"}

      pending = event(socket, "filter", %{"status" => "pending"})
      assert ctx.org.id in Enum.map(pending.assigns.rows, & &1.organization.id)

      suspended = event(socket, "filter", %{"status" => "suspended"})
      refute ctx.org.id in Enum.map(suspended.assigns.rows, & &1.organization.id)
    end

    test "approves, suspends and reactivates, keeping the note", ctx do
      socket = mount_live(PlatformLive.Organizations, ctx.operator)

      socket =
        event(socket, "set_status", %{
          "organization_id" => ctx.org.id,
          "status" => "active",
          "note" => "ok"
        })

      assert flash(socket, :info) =~ "disetujui"
      assert status(ctx.org) == "active"
      assert Organizations.get_organization!(ctx.org.id).reviewed_by_id == ctx.operator.id

      socket =
        event(socket, "set_status", %{
          "organization_id" => "#{ctx.org.id}",
          "status" => "suspended",
          "note" => "telat bayar"
        })

      assert flash(socket, :info) =~ "ditangguhkan"
      assert Organizations.get_organization!(ctx.org.id).review_note == "telat bayar"

      event(socket, "set_status", %{
        "organization_id" => ctx.org.id,
        "status" => "active",
        "note" => ""
      })

      assert status(ctx.org) == "active"
    end

    test "rejects a pending organization", ctx do
      socket =
        PlatformLive.Organizations
        |> mount_live(ctx.operator)
        |> event("set_status", %{
          "organization_id" => ctx.org.id,
          "status" => "rejected",
          "note" => "data tidak lengkap"
        })

      assert flash(socket, :info) =~ "ditolak"
      assert status(ctx.org) == "rejected"
    end

    test "refuses a status change that makes no sense", ctx do
      socket =
        PlatformLive.Organizations
        |> mount_live(ctx.operator)
        |> event("set_status", %{
          "organization_id" => ctx.org.id,
          "status" => "suspended",
          "note" => ""
        })

      assert flash(socket, :error) =~ "tidak bisa"
      assert status(ctx.org) == "pending"
    end

    test "records the manual billing", ctx do
      socket =
        PlatformLive.Organizations
        |> mount_live(ctx.operator)
        |> event("save_billing", %{
          "organization_id" => ctx.org.id,
          "billing" => %{"paid_until" => "2027-03-31", "billing_note" => "Transfer 6 bulan"}
        })

      assert flash(socket, :info) =~ "Tagihan"
      org = Organizations.get_organization!(ctx.org.id)
      assert {org.paid_until, org.billing_note} == {~D[2027-03-31], "Transfer 6 bulan"}
      assert html(socket) =~ "Transfer 6 bulan"
    end
  end

  describe "organizations waiting for approval" do
    setup do
      Map.put(pending_org(), :operator, superadmin_fixture())
    end

    defp title(0), do: "Organisasi"
    defp title(waiting), do: "(#{waiting}) Organisasi"

    defp chip(socket, status) do
      [tag] = Regex.run(~r{<button[^>]*id="status-#{status}"[^>]*>.*?</button>}s, html(socket))
      tag
    end

    defp approve(socket, org) do
      event(socket, "set_status", %{
        "organization_id" => org.id,
        "status" => "active",
        "note" => ""
      })
    end

    test "are counted on the page and in the tab title", ctx do
      socket = mount_live(PlatformLive.Organizations, ctx.operator)
      waiting = socket.assigns.counts["pending"]

      assert waiting >= 1
      assert socket.assigns.page_title == title(waiting)
      assert chip(socket, "pending") =~ "Menunggu"
      assert chip(socket, "pending") =~ ~r/>\s*#{waiting}\s*</

      approved = approve(socket, ctx.org)

      assert approved.assigns.counts["pending"] == waiting - 1
      assert approved.assigns.page_title == title(waiting - 1)
      assert chip(approved, "pending") =~ ~r/>\s*#{waiting - 1}\s*</
    end

    test "the status chips filter the list and show which one is chosen", ctx do
      socket = mount_live(PlatformLive.Organizations, ctx.operator)

      assert chip(socket, "all") =~ "chip-active"
      refute chip(socket, "pending") =~ "chip-active"

      pending = event(socket, "filter", %{"status" => "pending"})

      assert chip(pending, "pending") =~ "chip-active"
      refute chip(pending, "all") =~ "chip-active"
      assert Enum.all?(pending.assigns.rows, &(&1.organization.status == "pending"))

      # The counts are of every organization, whatever the list is filtered to.
      assert pending.assigns.counts == socket.assigns.counts
    end

    test "a sign-up while the page is open appears without a reload", ctx do
      socket = mount_live(PlatformLive.Organizations, ctx.operator, connected: true)
      waiting = socket.assigns.counts["pending"]

      %{org: new} = pending_org()
      new_id = new.id
      assert_receive {:organizations_changed, ^new_id}

      socket = info(socket, {:organizations_changed, new_id})

      assert socket.assigns.counts["pending"] == waiting + 1
      assert socket.assigns.page_title == title(waiting + 1)
      assert new_id in Enum.map(socket.assigns.rows, & &1.organization.id)
    end

    test "the first, static render does not subscribe", ctx do
      mount_live(PlatformLive.Organizations, ctx.operator)

      %{org: new} = pending_org()
      new_id = new.id
      refute_receive {:organizations_changed, ^new_id}, 50
    end
  end
end
