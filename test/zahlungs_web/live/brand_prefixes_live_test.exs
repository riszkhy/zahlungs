defmodule ZahlungsWeb.BrandPrefixesLiveTest do
  @moduledoc """
  The platform operator's "Awalan nomor" page, and the cashier screen using
  what it saved. The prefixes are one table for every organization: not
  async, so two tests don't rewrite it at once.
  """
  use ZahlungsWeb.ConnCase, async: false

  import Zahlungs.AccountsFixtures
  import Zahlungs.StoresFixtures
  import Zahlungs.ServicesFixtures
  import ZahlungsWeb.LiveDriver

  alias Zahlungs.{Accounts, Services}
  alias Zahlungs.Services.Brand
  alias ZahlungsWeb.{PlatformLive, ServiceLive}

  setup do
    {:ok, _} = Services.reset_brand_prefixes()
    :ok
  end

  defp form(changes) do
    Brand.default_prefixes()
    |> Map.new(fn {brand, list} -> {brand, Enum.join(list, ", ")} end)
    |> Map.merge(changes)
  end

  describe "access" do
    test "guests are sent to log in", %{conn: conn} do
      assert conn |> get("/platform/brands") |> redirected_to() == "/users/log_in"
    end

    test "an organization's admin can't open it", %{conn: conn} do
      {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
      assert conn |> log_in_user(admin) |> get("/platform/brands") |> redirected_to() == "/"
    end

    test "the operator sees every brand's prefixes, and the menu links there", %{conn: conn} do
      response = conn |> log_in_user(superadmin_fixture()) |> get("/platform/brands")
      html = html_response(response, 200)

      assert html =~ "Awalan nomor"
      assert html =~ ~s(name="prefixes[telkomsel]")
      assert html =~ "0812"
      assert html =~ ~s(name="prefixes[byu]")
      assert html =~ ~s(href="/platform/brands")
    end
  end

  describe "editing" do
    setup do
      %{socket: mount_live(PlatformLive.Brands, superadmin_fixture())}
    end

    test "saves the prefixes", %{socket: socket} do
      socket =
        event(socket, "save", %{
          "prefixes" => form(%{"telkomsel" => "0811, 0899", "tri" => "0895"})
        })

      assert flash(socket, :info) =~ "disimpan"
      assert Services.brand_prefixes()["telkomsel"] == ~w(0811 0899)
      assert html(socket) =~ "0811, 0899"
    end

    test "a wrong prefix is shown at its brand and nothing is saved", %{socket: socket} do
      socket = event(socket, "save", %{"prefixes" => form(%{"byu" => "0812, 81"})})

      rendered = html(socket)
      assert rendered =~ "Telkomsel"
      assert rendered =~ "0812, 81"
      assert socket.assigns.errors["byu"] =~ "81"
      assert Services.brand_prefixes() == Brand.default_prefixes()
    end

    test "Kembalikan bawaan brings the defaults back", %{socket: socket} do
      socket = event(socket, "save", %{"prefixes" => form(%{"telkomsel" => "0811"})})
      socket = event(socket, "reset")

      assert flash(socket, :info) =~ "bawaan"
      assert Services.brand_prefixes() == Brand.default_prefixes()
      assert socket.assigns.values["telkomsel"] =~ "0812"
    end
  end

  test "the cashier screen knows a number by the saved prefixes" do
    {:ok, _} =
      Services.save_brand_prefixes(form(%{"telkomsel" => "0811, 0812, 0899", "tri" => "0895"}))

    assign_account(default_store(), deposit_account_fixture())
    cashier = Zahlungs.ShiftsFixtures.user_on_shift_fixture()

    socket =
      ServiceLive.Index
      |> mount_live(cashier)
      |> event("set_category", %{"category" => "pulsa"})
      |> event("change", %{"service" => %{"customer_ref" => "0899 1234"}})

    assert socket.assigns.brand == "telkomsel"
  end
end
