defmodule Zahlungs.Promotions do
  @moduledoc """
  Promotions: a percent or rupiah discount on products or categories, for a
  range of store-local dates, in all stores or chosen ones. Only an admin
  manages them.

  A sale line gets at most one promotion, the one taking off the most;
  consignment products never get one. The cashier screen and
  `Zahlungs.Sales.create_sale/3` use the same `apply/2`, and the sale works it
  out again in its own transaction, so a screen can't set a price.

  Also here: the limit on a cashier's manual discount, per organization.
  """

  import Ecto.Query, warn: false

  alias Zahlungs.Accounts.User
  alias Zahlungs.Catalog.{Category, Product}
  alias Zahlungs.Organizations.Organization
  alias Zahlungs.Promotions.{Promotion, PromotionStore, PromotionTarget}
  alias Zahlungs.{LocalTime, Repo}
  alias Zahlungs.Stores.Store

  @doc """
  The organization's promotions, latest first, as `%{promotion, status}`:
  `:running`, `:scheduled`, `:ended` or `:inactive`, by today's date.
  """
  def list_promotions do
    today = LocalTime.today(nil)

    Promotion
    |> order_by(desc: :starts_on, desc: :id)
    |> preload(targets: [:product, :category], stores: :store)
    |> Repo.all()
    |> Enum.map(&%{promotion: &1, status: status(&1, today)})
  end

  defp status(%Promotion{active: false}, _today), do: :inactive

  defp status(promotion, today) do
    cond do
      Date.before?(today, promotion.starts_on) -> :scheduled
      Date.after?(today, promotion.ends_on) -> :ended
      true -> :running
    end
  end

  @doc "A promotion of the current organization, its target and store ids filled in."
  def get_promotion!(id) do
    Promotion
    |> Repo.get!(id)
    |> Repo.preload([:targets, :stores])
    |> fill_ids()
  end

  defp fill_ids(%Promotion{} = promotion) do
    %{
      promotion
      | product_ids: for(%{product_id: id} <- promotion.targets, id, do: id),
        category_ids: for(%{category_id: id} <- promotion.targets, id, do: id),
        store_ids: Enum.map(promotion.stores, & &1.store_id)
    }
  end

  @doc "A changeset for the promotion form."
  def change_promotion(%Promotion{} = promotion, attrs \\ %{}),
    do: Promotion.changeset(promotion, attrs)

  @doc """
  Creates a promotion with its targets (`product_ids`, `category_ids`) and,
  when not `all_stores`, its `store_ids`. Admins only.
  """
  def create_promotion(%User{role: "admin"} = user, attrs) do
    Repo.put_org_id(user.organization_id)
    save(%Promotion{}, attrs)
  end

  def create_promotion(_user, _attrs), do: {:error, :unauthorized}

  @doc "Changes a promotion; its targets and stores are replaced. Admins only."
  def update_promotion(%User{role: "admin"} = user, %Promotion{} = promotion, attrs) do
    Repo.put_org_id(user.organization_id)
    save(get_promotion!(promotion.id), attrs)
  end

  def update_promotion(_user, _promotion, _attrs), do: {:error, :unauthorized}

  @doc "Turns a promotion on or off. Admins only."
  def set_active(%User{role: "admin"} = user, %Promotion{} = promotion, active?),
    do: update_promotion(user, promotion, %{active: active?})

  def set_active(_user, _promotion, _active?), do: {:error, :unauthorized}

  defp save(promotion, attrs) do
    changeset =
      promotion
      |> Promotion.changeset(attrs)
      |> owned(:product_ids, Product)
      |> owned(:category_ids, Category)
      |> owned(:store_ids, Store)

    Repo.transaction(fn ->
      case Repo.insert_or_update(changeset) do
        {:ok, saved} -> replace_links(saved)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Ids from the form must be rows of the current organization (the Repo
  # guard filters these queries to it).
  defp owned(changeset, field, schema) do
    ids = Ecto.Changeset.get_field(changeset, field) |> Enum.uniq()
    found = Repo.all(from r in schema, where: r.id in ^ids, select: r.id)

    if length(found) == length(ids),
      do: Ecto.Changeset.put_change(changeset, field, ids),
      else: Ecto.Changeset.add_error(changeset, field, "tidak ditemukan")
  end

  defp replace_links(%Promotion{id: id} = promotion) do
    Repo.delete_all(from t in PromotionTarget, where: t.promotion_id == ^id)
    Repo.delete_all(from s in PromotionStore, where: s.promotion_id == ^id)

    targets =
      Enum.map(promotion.product_ids, &%{promotion_id: id, product_id: &1}) ++
        Enum.map(promotion.category_ids, &%{promotion_id: id, category_id: &1})

    Repo.insert_all(PromotionTarget, targets)

    unless promotion.all_stores do
      Repo.insert_all(
        PromotionStore,
        Enum.map(promotion.store_ids, &%{promotion_id: id, store_id: &1})
      )
    end

    promotion
  end

  @doc "The most a cashier may take off a sale by hand, in percent, or nil for no limit."
  def cashier_discount_limit(organization_id) do
    Repo.one(
      from o in Organization,
        where: o.id == ^organization_id,
        select: o.max_cashier_discount_percent
    )
  end

  @doc "Sets (or, blank, removes) the limit on a cashier's manual discount. Admins only."
  def set_cashier_discount_limit(%User{role: "admin"} = user, value) do
    value = if is_binary(value) and String.trim(value) == "", do: nil, else: value

    Organization
    |> Repo.get!(user.organization_id)
    |> Organization.discount_limit_changeset(%{max_cashier_discount_percent: value})
    |> Repo.update()
  end

  def set_cashier_discount_limit(_user, _value), do: {:error, :unauthorized}
end
