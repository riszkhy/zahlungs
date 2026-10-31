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
  # apply/2 below is this module's: the promotion rule.
  import Kernel, except: [apply: 2]

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

  @doc """
  The promotions running in `store` on the store-local `date` (both ends of a
  promotion's range included), with their targets, oldest first. Without a
  store, only those for all stores.
  """
  def active_for(store, %Date{} = date) do
    # Without a store no promotion_stores row can match (store id 0).
    store_id = (store && store.id) || 0

    in_store =
      from s in PromotionStore, where: s.store_id == ^store_id, select: s.promotion_id

    Repo.all(
      from p in Promotion,
        where:
          p.active and p.starts_on <= ^date and p.ends_on >= ^date and
            (p.all_stores or p.id in subquery(in_store)),
        order_by: p.id,
        preload: :targets
    )
  end

  @doc """
  Gives each line (`%{product: %{id, category_id, consignment}, quantity,
  unit_price}`) its promotion: `discount`, `promotion_id`, `promotion_name`
  (0, nil, nil without one). Of the promotions matching the product or its
  category, the one taking off the most wins; a tie goes to the oldest.
  Consignment products never get one. Pure: no database.
  """
  def apply(lines, promotions) do
    Enum.map(lines, fn line ->
      best =
        promotions
        |> Enum.filter(&matches?(&1, line.product))
        |> Enum.map(&{discount_for(&1, line.unit_price, line.quantity), &1})
        |> Enum.reduce(nil, &better/2)

      case best do
        {discount, promotion} ->
          Map.merge(line, %{
            discount: discount,
            promotion_id: promotion.id,
            promotion_name: promotion.name
          })

        nil ->
          Map.merge(line, %{discount: Decimal.new(0), promotion_id: nil, promotion_name: nil})
      end
    end)
  end

  # The larger discount, or on a tie the older promotion (smaller id).
  defp better(candidate, nil), do: candidate

  defp better({discount, promotion} = candidate, {best_discount, best} = current) do
    case Decimal.compare(discount, best_discount) do
      :gt -> candidate
      :eq when promotion.id < best.id -> candidate
      _ -> current
    end
  end

  defp matches?(_promotion, %{consignment: true}), do: false

  defp matches?(%Promotion{targets: targets}, product) do
    Enum.any?(targets, fn target ->
      (target.product_id && target.product_id == product.id) ||
        (target.category_id && target.category_id == product.category_id)
    end)
  end

  @doc """
  What `promotion` takes off a line: a percent of it floored to the rupiah,
  or rupiah per unit; never more than the line.
  """
  def discount_for(%Promotion{} = promotion, unit_price, quantity) do
    line = Decimal.mult(unit_price, quantity)

    off =
      case promotion.kind do
        "percent" ->
          line |> Decimal.mult(promotion.value) |> Decimal.div(100) |> Decimal.round(0, :floor)

        "amount" ->
          Decimal.mult(promotion.value, quantity)
      end

    Decimal.min(off, line)
  end

  @doc """
  What each promotion took off in a range of local dates, from completed
  sales of the scope's store (every store of the organization for "all
  stores"), largest first: `[%{promotion_id, name, items, discount,
  revenue}]` (`revenue` is after the discount).
  """
  def report(%Zahlungs.Scope{} = scope, %Date{} = from, %Date{} = to) do
    {start, finish} = LocalTime.day_range(from, to, scope.store)

    store_ids =
      case Zahlungs.Scope.store_id(scope) do
        nil -> Zahlungs.Stores.store_ids()
        store_id -> [store_id]
      end

    Repo.all(
      from i in Zahlungs.Sales.SaleItem,
        join: s in assoc(i, :sale),
        where:
          s.store_id in ^store_ids and s.status == "completed" and s.inserted_at >= ^start and
            s.inserted_at <= ^finish and not is_nil(i.promotion_name),
        group_by: [i.promotion_id, i.promotion_name],
        order_by: [desc: sum(i.discount)],
        select: %{
          promotion_id: i.promotion_id,
          name: i.promotion_name,
          items: type(sum(i.quantity), :integer),
          discount: sum(i.discount),
          revenue: sum(i.line_total)
        }
    )
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
