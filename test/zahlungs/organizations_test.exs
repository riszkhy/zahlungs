defmodule Zahlungs.OrganizationsTest do
  @moduledoc """
  Several owners in one database: what one organization has, another must never
  see or change — plus sign-up and the platform operator's review.
  """
  use Zahlungs.DataCase, async: true

  import Zahlungs.AccountsFixtures
  import Zahlungs.CatalogFixtures
  import Zahlungs.ShiftsFixtures
  import Zahlungs.StoresFixtures

  alias Zahlungs.{Accounts, Catalog, Organizations, Sales, Scope, Shifts, Stores}
  alias Zahlungs.Organizations.Organization

  defp admin_fixture(attrs \\ %{}) do
    {:ok, admin} = Accounts.set_user_role(user_fixture(attrs), "admin")
    admin
  end

  # A second organization with its own store, admin, cashier on shift, product
  # and one sale. Leaves the test's default organization current.
  defp other_org_fixture do
    org = organization_fixture()

    in_org(org, fn ->
      store = store_fixture(code: "TU")
      admin = admin_fixture(store_id: store.id)
      cashier = user_fixture(store_id: store.id)
      category = Catalog.create_category(%{name: "Minuman"}) |> elem(1)

      {:ok, product} =
        Catalog.create_product(Scope.for_store(store), %{
          name: "Produk B",
          sku: "SKU-1",
          price: Decimal.new("1000"),
          stock: 5,
          category_id: category.id
        })

      shift_fixture(cashier)

      {:ok, sale} =
        Sales.create_sale(cashier, [%{product_id: product.id, quantity: 1}], %{
          amount_paid: "1000"
        })

      %{
        org: org,
        store: store,
        admin: admin,
        cashier: cashier,
        category: category,
        product: product,
        sale: sale
      }
    end)
  end

  describe "the tenant guard" do
    test "refuses a query on an owned table when there is no current organization" do
      Zahlungs.Repo.put_org_id(nil)

      assert_raise ArgumentError, ~r/without a current organization/, fn ->
        Catalog.list_categories()
      end

      assert is_list(Zahlungs.Repo.all(Zahlungs.Catalog.Category, skip_org_id: true))
    end
  end

  describe "isolation between organizations" do
    setup do
      %{b: other_org_fixture(), mine: admin_fixture()}
    end

    test "catalog, stores and users of another organization are invisible", %{b: b} do
      refute b.category.id in Enum.map(Catalog.list_categories(), & &1.id)
      refute b.store.id in Enum.map(Stores.list_stores(), & &1.id)
      refute b.cashier.id in Enum.map(Accounts.list_users(), & &1.id)
      assert Catalog.list_products(store_scope(), search: "Produk B") == []
      assert Catalog.get_product_by_code(store_scope(), "SKU-1") == nil

      assert_raise Ecto.NoResultsError, fn ->
        Catalog.get_product!(store_scope(), b.product.id)
      end

      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(b.cashier.id) end
      assert_raise Ecto.NoResultsError, fn -> Stores.get_store!(b.store.id) end
      assert Stores.get_active_store(b.store.id) == nil
    end

    test "an admin over all stores sees only their own organization's sales and shifts",
         %{b: b, mine: mine} do
      scope = all_stores_scope(mine)
      today = Zahlungs.LocalTime.today()

      assert Sales.list_sales(scope, limit: 1000) == []
      assert Sales.count_sales(scope) == 0
      assert Sales.sales_report(scope, today, today).transactions == 0
      assert Sales.sales_by_store(scope, today, today) == []
      assert Shifts.list_shifts(scope) == []

      assert_raise Ecto.NoResultsError, fn -> Sales.get_sale!(scope, b.sale.id) end

      # ...while the other organization's own admin sees it.
      theirs = all_stores_scope(b.admin)
      assert Enum.map(Sales.list_sales(theirs), & &1.id) == [b.sale.id]
      assert length(Shifts.list_shifts(theirs)) == 1
    end

    test "a cashier cannot sell another organization's product", %{b: b} do
      cashier = user_on_shift_fixture()

      assert {:error, :empty_cart} =
               Sales.create_sale(cashier, [%{product_id: b.product.id, quantity: 1}], %{
                 amount_paid: "1000"
               })

      in_org(b.org, fn -> assert stock_of(b.product, b.store) == 4 end)
    end

    test "codes are unique per organization, not across them", %{b: b} do
      # The other organization already has store TU, category Minuman, SKU-1.
      assert {:ok, _} = Stores.create_store(%{name: "Toko Utama", code: "TU"})
      assert {:ok, _} = Catalog.create_category(%{name: "Minuman"})
      assert %{sku: "SKU-1"} = product_fixture(sku: "SKU-1")

      assert {:error, changeset} = Catalog.create_category(%{name: "Minuman"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)

      in_org(b.org, fn ->
        assert {:error, changeset} = Stores.create_store(%{name: "Lagi", code: "TU"})
        assert %{code: ["has already been taken"]} = errors_on(changeset)
      end)
    end

    test "an email belongs to one account across all organizations", %{b: b} do
      assert {:error, changeset} =
               Accounts.create_user(%{
                 email: b.cashier.email,
                 password: valid_user_password(),
                 role: "cashier",
                 store_id: default_store().id
               })

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "the login log is per organization", %{b: b, mine: mine} do
      {:ok, _} = Accounts.record_login(b.cashier)
      {:ok, own} = Accounts.record_login(mine)

      Scope.for_user(mine)
      assert Enum.map(Accounts.list_user_logins(), & &1.id) == [own.id]
    end
  end

  describe "register/1" do
    @valid %{
      "business_name" => "Toko Berkah",
      "phone" => "0812-1111",
      "name" => "Bu Sari",
      "password" => "rahasia-sekali-123"
    }

    test "creates a pending organization with a first store and its owner" do
      email = unique_user_email()
      before = Zahlungs.Repo.get_org_id()

      assert {:ok, %{organization: org, store: store, owner: owner}} =
               Organizations.register(Map.put(@valid, "email", email))

      assert {org.name, org.status, org.phone} == {"Toko Berkah", "pending", "0812-1111"}
      assert {store.name, store.code, store.organization_id} == {"Toko Utama", "TU", org.id}

      assert {owner.role, owner.organization_id, owner.store_id, owner.name} ==
               {"admin", org.id, store.id, "Bu Sari"}

      assert owner.confirmed_at
      assert Accounts.get_user_by_email_and_password(email, "rahasia-sekali-123")
      # Registering does not move the caller into the new organization.
      assert Zahlungs.Repo.get_org_id() == before
    end

    test "the owner cannot use the application until the organization is approved" do
      {:ok, %{owner: owner}} =
        Organizations.register(Map.put(@valid, "email", unique_user_email()))

      scope = Scope.for_user(owner)

      assert Scope.block_reason(scope) == :pending
      refute Scope.usable?(scope)
    end

    test "invalid input creates nothing" do
      assert {:error, changeset} =
               Organizations.register(%{
                 "business_name" => "",
                 "email" => "nope",
                 "password" => "x"
               })

      assert %{business_name: [_ | _], name: [_ | _], email: [_ | _], password: [_ | _]} =
               errors_on(changeset)
    end

    test "an email already in use is reported on the form and nothing is created" do
      taken = user_fixture().email

      assert {:error, changeset} =
               Organizations.register(
                 @valid
                 |> Map.put("email", taken)
                 |> Map.put("business_name", "Toko Kembar 7781")
               )

      assert %{email: ["has already been taken"]} = errors_on(changeset)

      refute Enum.any?(
               Organizations.list_organizations(),
               &(&1.organization.name == "Toko Kembar 7781")
             )
    end
  end

  describe "review by the platform operator" do
    setup do
      {:ok, %{organization: org, owner: owner}} =
        Organizations.register(Map.put(@valid, "email", unique_user_email()))

      %{org: org, owner: owner, operator: superadmin_fixture()}
    end

    test "approval lets the owner in and records who approved", ctx do
      assert {:ok, org} = Organizations.set_status(ctx.org, "active", ctx.operator, "ok")

      assert {org.status, org.reviewed_by_id, org.review_note} ==
               {"active", ctx.operator.id, "ok"}

      assert org.reviewed_at
      assert Scope.usable?(Scope.for_user(ctx.owner))
    end

    test "rejection and suspension keep the owner out", ctx do
      {:ok, rejected} = Organizations.set_status(ctx.org, "rejected", ctx.operator, "data palsu")
      assert Scope.block_reason(Scope.for_user(ctx.owner)) == :rejected

      {:ok, active} = Organizations.set_status(rejected, "active", ctx.operator)

      {:ok, suspended} =
        Organizations.set_status(active, "suspended", ctx.operator, "belum bayar")

      assert Scope.block_reason(Scope.for_user(ctx.owner)) == :suspended

      {:ok, _} = Organizations.set_status(suspended, "active", ctx.operator)
      assert Scope.usable?(Scope.for_user(ctx.owner))
    end

    test "status changes that make no sense are refused", ctx do
      assert {:error, :invalid_transition} =
               Organizations.set_status(ctx.org, "suspended", ctx.operator)

      assert {:error, :invalid_transition} =
               Organizations.set_status(ctx.org, "pending", ctx.operator)

      assert Organizations.get_organization!(ctx.org.id).status == "pending"
    end

    test "billing is recorded by hand", ctx do
      assert {:ok, org} =
               Organizations.update_billing(ctx.org, %{
                 "paid_until" => "2027-01-31",
                 "billing_note" => "Transfer BCA 3 bulan"
               })

      assert {org.paid_until, org.billing_note} == {~D[2027-01-31], "Transfer BCA 3 bulan"}
    end

    test "counts organizations by status, with every status present", ctx do
      before = Organizations.count_by_status()

      assert Enum.sort(Map.keys(before)) == Enum.sort(Organization.statuses())
      assert before["pending"] >= 1

      {:ok, _} = Organizations.set_status(ctx.org, "active", ctx.operator)
      later = Organizations.count_by_status()

      assert later["pending"] == before["pending"] - 1
      assert later["active"] == before["active"] + 1
      assert later["suspended"] == before["suspended"]
    end

    test "sign-ups and reviews are announced to whoever subscribed", ctx do
      :ok = Organizations.subscribe()

      {:ok, %{organization: new}} =
        Organizations.register(Map.put(@valid, "email", unique_user_email()))

      new_id = new.id
      assert_receive {:organizations_changed, ^new_id}

      reviewed_id = ctx.org.id
      {:ok, _} = Organizations.set_status(ctx.org, "rejected", ctx.operator)
      assert_receive {:organizations_changed, ^reviewed_id}

      # A change that was refused is not news.
      {:error, :invalid_transition} = Organizations.set_status(new, "suspended", ctx.operator)
      refute_receive {:organizations_changed, ^new_id}, 50
    end

    test "the operator's list shows each organization's owner and size", ctx do
      row =
        Enum.find(Organizations.list_organizations(status: "pending"), fn row ->
          row.organization.id == ctx.org.id
        end)

      assert {row.owner_email, row.users, row.stores} == {ctx.owner.email, 1, 1}

      refute Enum.any?(Organizations.list_organizations(status: "suspended"), fn row ->
               row.organization.id == ctx.org.id
             end)
    end
  end

  describe "the platform operator" do
    test "belongs to no organization and has no store" do
      operator = superadmin_fixture()
      scope = Scope.for_user(operator)

      assert Scope.platform_admin?(scope)
      refute Scope.usable?(scope)
      assert {operator.organization_id, operator.role} == {nil, "superadmin"}
      assert Zahlungs.Repo.get_org_id() == nil
      assert %Organization{} = hd(Enum.map(Organizations.list_organizations(), & &1.organization))
    end
  end
end
