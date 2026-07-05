# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Zahlungs.Repo.insert!(%Zahlungs.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Zahlungs.Accounts
alias Zahlungs.Accounts.User
alias Zahlungs.Repo

defmodule Seeds do
  @doc "Idempotently create a confirmed user with the given role."
  def ensure_user(email, password, role, name) do
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} = Accounts.register_user(%{name: name, email: email, password: password})

        user =
          if role == "cashier" do
            user
          else
            {:ok, user} = Accounts.set_user_role(user, role)
            user
          end

        # Mark as confirmed so the seeded accounts are ready to use.
        user |> User.confirm_changeset() |> Repo.update!()
        IO.puts("Seeded #{role}: #{email}")

      _existing ->
        IO.puts("Skipped (already exists): #{email}")
    end
  end
end

# Which environment are we seeding? (:prod inside a release, :dev/:test via mix)
env = Application.get_env(:zahlungs, :env, :prod)

# Accounts. In dev/test, weak defaults are convenient; in PROD the credentials
# MUST come from env vars — we never seed the well-known dev passwords there.
seed_admin = fn email, password, name ->
  Seeds.ensure_user(email, password, "admin", name)
end

seed_cashier = fn email, password, name ->
  Seeds.ensure_user(email, password, "cashier", name)
end

if env == :prod do
  admin_email = System.get_env("SEED_ADMIN_EMAIL")
  admin_password = System.get_env("SEED_ADMIN_PASSWORD")

  if admin_email && admin_password do
    seed_admin.(admin_email, admin_password, System.get_env("SEED_ADMIN_NAME") || "Administrator")
  else
    IO.puts("Skipped admin seed: set SEED_ADMIN_EMAIL and SEED_ADMIN_PASSWORD to create one.")
  end

  cashier_email = System.get_env("SEED_CASHIER_EMAIL")
  cashier_password = System.get_env("SEED_CASHIER_PASSWORD")

  if cashier_email && cashier_password do
    seed_cashier.(cashier_email, cashier_password, System.get_env("SEED_CASHIER_NAME") || "Kasir")
  end
else
  seed_admin.("admin@zahlungs.test", "adminpassword123", "Administrator")
  seed_cashier.("cashier@zahlungs.test", "cashierpassword123", "Kasir Utama")
end

## Sample catalog data (idempotent by name / SKU) — dev/test only, never prod.

alias Zahlungs.Catalog
alias Zahlungs.Catalog.{Category, Product}

defmodule CatalogSeeds do
  def ensure_category(name) do
    case Repo.get_by(Category, name: name) do
      nil ->
        {:ok, category} = Catalog.create_category(%{name: name})
        IO.puts("Seeded category: #{name}")
        category

      category ->
        category
    end
  end

  def ensure_product(attrs) do
    case Repo.get_by(Product, sku: attrs.sku) do
      nil ->
        {:ok, _} = Catalog.create_product(attrs)
        IO.puts("Seeded product: #{attrs.sku}")

      _existing ->
        :ok
    end
  end
end

if env != :prod do
  drinks = CatalogSeeds.ensure_category("Drinks")
  snacks = CatalogSeeds.ensure_category("Snacks")
  _staples = CatalogSeeds.ensure_category("Staples")

  CatalogSeeds.ensure_product(%{
    sku: "DRK-001",
    name: "Mineral Water 600ml",
    price: Decimal.new("3500"),
    stock: 100,
    category_id: drinks.id
  })

  CatalogSeeds.ensure_product(%{
    sku: "DRK-002",
    name: "Iced Coffee 250ml",
    price: Decimal.new("12000"),
    stock: 40,
    category_id: drinks.id
  })

  CatalogSeeds.ensure_product(%{
    sku: "SNK-001",
    name: "Potato Chips 68g",
    price: Decimal.new("9500"),
    stock: 25,
    category_id: snacks.id
  })

  CatalogSeeds.ensure_product(%{
    sku: "SNK-002",
    name: "Chocolate Bar 45g",
    price: Decimal.new("8000"),
    stock: 3,
    category_id: snacks.id
  })
end
