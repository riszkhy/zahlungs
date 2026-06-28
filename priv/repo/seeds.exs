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
  def ensure_user(email, password, role) do
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} = Accounts.register_user(%{email: email, password: password})

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

# Default accounts (change passwords before any real deployment).
Seeds.ensure_user("admin@zahlungs.test", "adminpassword123", "admin")
Seeds.ensure_user("cashier@zahlungs.test", "cashierpassword123", "cashier")

## Sample catalog data (idempotent by name / SKU)

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
