defmodule Zahlungs.HeldCarts do
  @moduledoc """
  Held carts (Tunda): a cart the cashier puts aside to serve the next
  customer, and resumes later from any tablet of the same store.

  Every function takes the store from the user's open shift, as
  `Zahlungs.Sales.create_sale/3` does; without one it is
  `{:error, :no_open_shift}`. The store never comes from params.

  A held cart keeps products and quantities, not prices or stock: resuming
  reads both again. Holding touches neither stock, the drawer nor the
  reports; they move only when the sale is completed.

  Every change is broadcast to the store (`subscribe/1`), so the other
  tablets of the store see held carts come and go.
  """

  import Ecto.Query, warn: false

  alias Zahlungs.{Catalog, Repo, Scope, Shifts, Stores}
  alias Zahlungs.Catalog.Product
  alias Zahlungs.HeldCarts.{HeldCart, HeldCartItem}

  @doc """
  Holds `items` (`[%{product_id: id, quantity: n}]`) with `attrs` (`note`,
  `discount`, `tax`) in the store of the user's open shift.
  """
  def hold(user, items, attrs)

  def hold(_user, [], _attrs), do: {:error, :empty_cart}

  def hold(user, items, attrs) do
    with {:ok, shift, store} <- shift_store(user) do
      fn -> insert_held(user, shift, store, items, attrs) end
      |> Repo.transaction()
      |> broadcast(store)
    end
  end

  @doc "Subscribes the caller to `{:held_carts_changed, store_id}` for a store."
  def subscribe(store_id), do: Phoenix.PubSub.subscribe(Zahlungs.PubSub, topic(store_id))

  defp broadcast({:ok, _} = result, store) do
    Phoenix.PubSub.broadcast(Zahlungs.PubSub, topic(store.id), {:held_carts_changed, store.id})
    result
  end

  defp broadcast(result, _store), do: result

  defp topic(store_id), do: "held_carts:store:#{store_id}"

  # Names come from the product rows, a product deleted meanwhile included:
  # the cart on screen still has it, and resuming drops it.
  defp insert_held(user, shift, store, items, attrs) do
    ids = Enum.map(items, & &1.product_id)
    names = Map.new(Repo.all(from p in Product, where: p.id in ^ids, select: {p.id, p.name}))

    held =
      %HeldCart{store_id: store.id, user_id: user.id, shift_id: shift.id}
      |> HeldCart.changeset(attrs)
      |> Repo.insert()
      |> rollback_on_error()

    rows =
      for %{product_id: id, quantity: quantity} <- items do
        name = Map.get(names, id) || Repo.rollback(:not_found)

        %HeldCartItem{held_cart_id: held.id}
        |> HeldCartItem.changeset(%{product_id: id, quantity: quantity, name: name})
        |> Repo.insert()
        |> rollback_on_error()
      end

    %{held | items: rows}
  end

  @doc """
  The held carts of the store of the user's open shift, newest first, as
  `%{id, note, inserted_at, units, total}`: `total` is today's prices of the
  products still sold, less the discount, plus the tax.
  """
  def list(user) do
    case shift_store(user) do
      {:ok, _shift, store} ->
        held =
          Repo.all(from h in HeldCart, where: h.store_id == ^store.id, order_by: [desc: h.id])

        lines = lines_of(Enum.map(held, & &1.id))

        Enum.map(held, fn h ->
          own = Map.get(lines, h.id, [])
          subtotal = Enum.reduce(own, Decimal.new(0), &Decimal.add(&2, line_total(&1)))

          %{
            id: h.id,
            note: h.note,
            inserted_at: h.inserted_at,
            units: Enum.reduce(own, 0, &(&1.quantity + &2)),
            total: subtotal |> Decimal.sub(h.discount) |> Decimal.add(h.tax)
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc "How many carts are held in the store of the user's open shift."
  def count(user) do
    case shift_store(user) do
      {:ok, _shift, store} ->
        Repo.aggregate(from(h in HeldCart, where: h.store_id == ^store.id), :count)

      {:error, _} ->
        0
    end
  end

  @doc """
  Takes a held cart out of the store of the user's open shift, once: it is
  locked, read and deleted in one transaction, so a second tablet asking for
  the same cart gets `{:error, :not_found}`.

  Returns the items with today's product (price, and stock in that store),
  the discount and the tax. A product deleted, inactive or out of stock is
  dropped, a quantity above the stock is cut to it; `adjusted` counts both.

  `put_aside` (`{items, attrs}`, as `hold/3` takes them) is the cart on the
  screen in a swap: held in the same transaction, so nothing is held when
  the resume finds nothing.
  """
  def resume(user, id, put_aside \\ nil) do
    with {:ok, shift, store} <- shift_store(user),
         {:ok, id} <- cast_id(id) do
      fn ->
        resumed = take(store, id)
        set_aside(user, shift, store, put_aside)
        resumed
      end
      |> Repo.transaction()
      |> broadcast(store)
    end
  end

  # The cart on the screen when another one is resumed (a swap): held in the
  # same transaction, so it isn't held when the resume finds nothing.
  defp set_aside(_user, _shift, _store, nil), do: :ok
  defp set_aside(_user, _shift, _store, {[], _attrs}), do: :ok

  defp set_aside(user, shift, store, {items, attrs}),
    do: insert_held(user, shift, store, items, attrs)

  defp take(store, id) do
    held =
      from(h in HeldCart,
        where: h.id == ^id and h.store_id == ^store.id,
        lock: "FOR UPDATE",
        preload: :items
      )
      |> Repo.one()

    if is_nil(held), do: Repo.rollback(:not_found)

    Repo.delete!(held)
    fit(held, Scope.for_store(store))
  end

  @doc "Deletes a held cart of the store of the user's open shift."
  def delete(user, id) do
    with {:ok, _shift, store} <- shift_store(user),
         {:ok, id} <- cast_id(id) do
      case Repo.delete_all(from h in HeldCart, where: h.id == ^id and h.store_id == ^store.id) do
        {1, _} ->
          broadcast({:ok, :deleted}, store)
          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  # Today's product for each item; the items it can't sell as held are
  # dropped or cut to the stock.
  defp fit(held, scope) do
    {kept, adjusted} =
      held.items
      |> Enum.sort_by(& &1.id)
      |> Enum.flat_map_reduce(0, fn item, adjusted ->
        case current_product(scope, item.product_id) do
          %Product{active: true, stock: stock} = product when stock >= item.quantity ->
            {[%{product: product, quantity: item.quantity}], adjusted}

          %Product{active: true, stock: stock} = product when stock > 0 ->
            {[%{product: product, quantity: stock}], adjusted + 1}

          _gone_or_empty ->
            {[], adjusted + 1}
        end
      end)

    %{items: kept, discount: held.discount, tax: held.tax, adjusted: adjusted}
  end

  defp current_product(scope, id) do
    Catalog.get_product!(scope, id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(_id), do: {:error, :not_found}

  # Quantities with today's price (nil for a deleted product), per held cart.
  defp lines_of([]), do: %{}

  defp lines_of(ids) do
    from(i in HeldCartItem,
      left_join: p in Product,
      on: p.id == i.product_id and is_nil(p.deleted_at),
      where: i.held_cart_id in ^ids,
      select: %{held_cart_id: i.held_cart_id, quantity: i.quantity, price: p.price}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.held_cart_id)
  end

  defp line_total(%{price: nil}), do: Decimal.new(0)
  defp line_total(%{price: price, quantity: quantity}), do: Decimal.mult(price, quantity)

  defp shift_store(user) do
    Repo.put_org_id(user.organization_id)

    case Shifts.current_shift(user) do
      nil -> {:error, :no_open_shift}
      shift -> {:ok, shift, Stores.get_store!(shift.store_id)}
    end
  end

  defp rollback_on_error({:ok, value}), do: value
  defp rollback_on_error({:error, reason}), do: Repo.rollback(reason)
end
