defmodule Zahlungs.Services do
  @moduledoc """
  PPOB services (Fase 0, no provider API): the products a store sells besides
  goods, their price, and the services sold. The cashier does the top-up in
  the provider's own app; Zahlungs records the money and the result.

  ## Price

  `margin(x)` is the product's rupiah margin, or `x × percent / 100` rounded up
  to the whole rupiah.

    * pulsa, paket data, token PLN: cost = the product's cost,
      price = cost + margin(cost).
    * a bill (tagihan): cost = bill + provider fee × months (the product's cost),
      price = bill + admin fee × months (a rupiah margin), or bill + percent of
      the bill. A bill entered by hand (Fase 0) is one month.

  ## Transactions

  A service is recorded when the money is taken (`record/3`, status
  `processing`). The store is the cashier's shift's store and the deposit
  account is that store's; neither comes from the caller.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Zahlungs.Repo

  alias Zahlungs.Accounts.User
  alias Zahlungs.{Deposits, LocalTime, Scope, Shifts, Stores}
  alias Zahlungs.Shifts.Shift
  alias Zahlungs.Services.{Brand, BrandPrefix, CatalogCache, Dispatcher, Inquiry, Product}
  alias Zahlungs.Services.{Provider, Ref, Transaction}

  @category_labels [
    {"pulsa", "Pulsa"},
    {"paket_data", "Paket data"},
    {"token_pln", "Token PLN"},
    {"tagihan", "Tagihan"}
  ]

  @doc "The categories as `{value, label}` pairs, in display order."
  def categories, do: @category_labels

  ## Products

  @doc """
  Lists products that aren't deleted, by name.

  Options: `:category`, `:active` (`true`/`false`).
  """
  def list_products(opts \\ []) do
    Product
    |> where([p], is_nil(p.deleted_at))
    |> filter(:category, opts[:category])
    |> filter(:active, opts[:active])
    |> order_by([p], p.name)
    |> Repo.all()
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, _field, ""), do: query
  defp filter(query, :category, category), do: where(query, [p], p.category == ^category)
  defp filter(query, :active, active), do: where(query, [p], p.active == ^active)

  @doc "Gets a product that isn't deleted (raises otherwise)."
  def get_product!(id) do
    Repo.one!(from p in Product, where: p.id == ^id and is_nil(p.deleted_at))
  end

  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc "Soft delete: hidden from lists, kept for the transactions that name it."
  def delete_product(%Product{} = product) do
    product
    |> Ecto.Changeset.change(deleted_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second))
    |> Repo.update()
  end

  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  ## Price

  @doc """
  The price to the customer and the cost to the shop, for a product and (for a
  bill, tagihan) the bill and its months (`sheets`). A bill without a positive
  amount has no price.
  """
  def price_for(%Product{} = product, bill_amount, sheets \\ 1) do
    if Product.bill?(product) do
      bill = to_decimal(bill_amount)

      if Decimal.gt?(bill, 0) do
        {:ok,
         %{
           price: Decimal.add(bill, bill_margin(product, bill, sheets)),
           cost: Decimal.add(bill, Decimal.mult(product.cost, sheets))
         }}
      else
        {:error, :bill_required}
      end
    else
      {:ok,
       %{price: Decimal.add(product.cost, margin(product, product.cost)), cost: product.cost}}
    end
  end

  ## Inquiry (Fase 1)

  @inquiry_timeout 15_000
  @inquiry_lifetime 15 * 60

  @doc """
  Asks the provider about a bill (tagihan), or a token PLN meter's owner, for a cashier on an open shift in a store
  with an api deposit account, and keeps the answer for 15 minutes
  (`Zahlungs.Services.Inquiry`). The provider gets 15 seconds.

  Returns `{:ok, inquiry}` (with its product) or `{:error, reason}`:
  `:no_open_shift`, `:no_deposit_account`, `:not_api`, `:product_unavailable`
  (not an active bill product), `:no_provider_code`, the provider's
  `:not_found` / `:already_paid` / `:unavailable` / `{:rejected, message}`, or a
  changeset (the customer number).

  `opts[:months]` (a number or text) is how many months the customer pays, for
  a bill product that asks (`ask_months`): blank means 1, 1 to 12 is that many,
  anything else is `{:error, :invalid_months}` before the provider is asked.
  A product that doesn't ask ignores it. The months go to the provider with the
  payment too, so when its answer states another month count the bill is
  refused (`{:error, {:rejected, "Penyedia menagih N bulan. ..."}}`, nothing
  stored) and the cashier asks again for that many; an answer that states no
  count is taken as the months asked.
  """
  def inquire(%User{} = user, product_id, customer_ref, opts \\ []) do
    Repo.put_org_id(user.organization_id)

    with {:ok, shift} <- open_shift(user),
         store = Stores.get_store!(shift.store_id),
         {:ok, account} <- api_account(store),
         {:ok, product} <- sellable_product(product_id),
         {:ok, kind} <- checkable(product),
         {:ok, months} <- months_asked(product, kind, opts[:months]),
         changeset =
           Inquiry.number_changeset(
             %Inquiry{
               store_id: store.id,
               user_id: user.id,
               service_product_id: product.id,
               deposit_account_id: account.id,
               ref_id: Ref.generate("Q", store.id),
               kind: kind,
               months: months
             },
             %{customer_ref: customer_ref || ""}
           ),
         {:ok, inquiry} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, answer} <- ask_provider(account, product, inquiry),
         :ok <- same_months(months, answer) do
      changeset
      |> Inquiry.answer_changeset(answer)
      |> Ecto.Changeset.put_change(:expires_at, NaiveDateTime.add(now(), @inquiry_lifetime))
      |> Repo.insert()
      |> case do
        {:ok, inquiry} -> {:ok, %{inquiry | service_product: product}}
        error -> error
      end
    end
  end

  @doc """
  What an inquired bill costs the customer and the shop: `%{price, cost}`. The
  customer pays the provider's total (bill and the provider's admin) plus the
  shop's `api_extra_fee` per sheet; the shop's cost is the provider's total
  until the provider says what it actually charged.
  """
  def inquiry_price(%Inquiry{kind: "customer", service_product: %Product{} = product}) do
    {:ok, price} = price_for(product, nil)
    price
  end

  def inquiry_price(%Inquiry{service_product: %Product{} = product} = inquiry) do
    total = inquiry.provider_total || inquiry.bill_amount

    %{
      price: Decimal.add(total, Decimal.mult(product.api_extra_fee, inquiry.sheets)),
      cost: total
    }
  end

  defp open_shift(user) do
    case Shifts.current_shift(user) do
      nil -> {:error, :no_open_shift}
      shift -> {:ok, shift}
    end
  end

  defp api_account(store) do
    case Deposits.get_active_account(store.deposit_account_id) do
      nil -> {:error, :no_deposit_account}
      account -> if Deposits.api?(account), do: {:ok, account}, else: {:error, :not_api}
    end
  end

  # What the provider is asked about: a bill, or the owner of a token PLN meter.
  defp checkable(%Product{category: category} = product)
       when category in ["tagihan", "token_pln"] do
    cond do
      blank_code?(product) -> {:error, :no_provider_code}
      category == "tagihan" -> {:ok, "bill"}
      true -> {:ok, "customer"}
    end
  end

  defp checkable(_product), do: {:error, :product_unavailable}

  defp blank_code?(%Product{provider_code: code}), do: code in [nil, ""]

  # The payment goes out with the months asked, so a bill the provider states for
  # other months must not be priced: the cashier asks again for its months.
  defp same_months(months, %{sheets: sheets})
       when is_integer(months) and is_integer(sheets) and sheets != months do
    {:error,
     {:rejected, "Penyedia menagih #{sheets} bulan. Pilih #{sheets} bulan lalu cek tagihan lagi."}}
  end

  defp same_months(_months, _answer), do: :ok

  # Only a bill product that asks has months; for anything else they're ignored.
  defp months_asked(%Product{ask_months: true}, "bill", asked), do: parse_months(asked)
  defp months_asked(_product, _kind, _asked), do: {:ok, nil}

  defp parse_months(nil), do: {:ok, 1}
  defp parse_months(months) when is_integer(months) and months in 1..12, do: {:ok, months}

  defp parse_months(months) when is_binary(months) do
    case String.trim(months) do
      "" ->
        {:ok, 1}

      text ->
        case Integer.parse(text) do
          {n, ""} when n in 1..12 -> {:ok, n}
          _ -> {:error, :invalid_months}
        end
    end
  end

  defp parse_months(_months), do: {:error, :invalid_months}

  # The provider gets @inquiry_timeout; past that it counts as unavailable.
  defp ask_provider(account, product, inquiry) do
    case Deposits.provider(account) do
      {:ok, adapter, credentials} ->
        task =
          Task.async(fn ->
            adapter.inquiry(credentials, %{
              ref_id: inquiry.ref_id,
              product_code: product.provider_code,
              check_code: product.provider_check_code,
              customer_ref: inquiry.customer_ref,
              kind: if(inquiry.kind == "customer", do: :customer, else: :bill),
              months: inquiry.months
            })
          end)

        case Task.yield(task, @inquiry_timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, answer} -> answer
          _ -> {:error, :unavailable}
        end

      _ ->
        {:error,
         {:rejected, "Kredensial penyedia tidak bisa dibaca. Minta admin mengisinya ulang."}}
    end
  end

  ## Recording

  @doc """
  Records a service when the cashier takes the money: status `processing`, on
  the cashier's open shift, in that shift's store, against the store's deposit
  account. The price and cost are worked out here and copied onto the
  transaction.

  `attrs` (string keys): `"customer_ref"`, `"bill_amount"` (tagihan PLN only),
  `"payment_method"` (default `"cash"`), `"amount_paid"` (cash only) and
  `"expected_price"`: the price the cashier quoted, when the screen knows it.

  Returns `{:ok, transaction}` or `{:error, reason}`: `:no_open_shift`,
  `:no_deposit_account`, `:product_unavailable`, `:bill_required`,
  `:insufficient_payment`, `:price_changed` (the product's price is no longer the
  quoted one), or a changeset (the customer number).
  """
  def record(%User{} = user, product_id, attrs) do
    # The cashier decides whose products and stores these are.
    Repo.put_org_id(user.organization_id)

    fn ->
      case insert_transaction(user, product_id, attrs) do
        {:ok, transaction} -> transaction
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> dispatch_api()
  end

  # An api service goes to the provider only once it is committed.
  defp dispatch_api({:ok, %Transaction{channel: "api"} = transaction} = result) do
    Dispatcher.dispatch(transaction)
    result
  end

  defp dispatch_api(result), do: result

  # Runs inside record/3's transaction: the shift stays locked until it ends.
  defp insert_transaction(user, product_id, attrs) do
    with {:ok, shift} <- Shifts.lock_current_shift(user),
         store = Stores.get_store!(shift.store_id),
         {:ok, account} <- store_account(store),
         {:ok, product} <- sellable_product(product_id),
         channel = if(Deposits.api?(account), do: "api", else: "manual"),
         :ok <- sellable_through(channel, product),
         {:ok, bill} <- bill_details(channel, product, store, attrs),
         {:ok, %{price: price, cost: cost}} <- priced(product, bill),
         :ok <- check_quoted_price(attrs["expected_price"], price),
         {:ok, payment} <- settle(attrs, price),
         :ok <- use_inquiry(bill.inquiry) do
      code = generate_code(store)

      %Transaction{
        store_id: store.id,
        shift_id: shift.id,
        user_id: user.id,
        service_product_id: product.id,
        deposit_account_id: account.id,
        code: code,
        ref_id: transaction_ref(channel, store, code, bill.inquiry),
        provider_code: if(channel == "api", do: product.provider_code),
        quoted_cost: cost,
        channel: channel,
        category: product.category,
        product_name: product.name,
        bill_amount: bill.amount,
        sheets: bill.sheets,
        customer_name: bill.customer_name,
        customer_details: bill.customer_details,
        period: bill.period,
        service_inquiry_id: bill.inquiry && bill.inquiry.id,
        price: price,
        cost: cost,
        amount_paid: payment.amount_paid,
        change_due: payment.change_due
      }
      |> Transaction.record_changeset(%{
        customer_ref: bill.customer_ref || attrs["customer_ref"] || "",
        payment_method: payment.method
      })
      |> Repo.insert()
    end
  end

  # A bill from an inquiry is priced from the provider's answer; anything else
  # from the product.
  defp priced(%Product{} = product, %{inquiry: %Inquiry{kind: "bill"} = inquiry}),
    do: {:ok, inquiry_price(%{inquiry | service_product: product})}

  defp priced(product, bill), do: price_for(product, bill.amount, bill.sheets)

  # What the provider knows the service by: a bill keeps its inquiry's ref (the
  # provider pays the bill it was asked about); other api services get their
  # own, unique across organizations; a manual one is its code.
  defp transaction_ref("api", _store, _code, %Inquiry{kind: "bill", ref_id: ref_id})
       when is_binary(ref_id),
       do: ref_id

  defp transaction_ref("api", store, _code, _inquiry), do: Ref.generate("Z", store.id)
  defp transaction_ref(_manual, _store, code, _inquiry), do: code

  # Through the provider, a product needs the vendor's code, and one the vendor
  # last said it can't sell (out of order, out of stock, unknown) is refused.
  defp sellable_through("api", product) do
    cond do
      blank_code?(product) -> {:error, :no_provider_code}
      product.provider_status not in [nil, "normal"] -> {:error, :product_unavailable}
      true -> :ok
    end
  end

  defp sellable_through(_manual, _product), do: :ok

  # An api bill, and a token PLN with the owner check, come from their
  # inquiry, locked and checked here: the shift's store, the same product,
  # unused, not expired. Anything else (a token without the check, like
  # pulsa) is entered.
  defp bill_details("api", %Product{category: category} = product, store, attrs)
       when category == "tagihan" or (category == "token_pln" and product.owner_check) do
    case lock_inquiry(attrs["inquiry_id"], store, product) do
      nil ->
        {:error, :inquiry_expired}

      inquiry ->
        {:ok,
         %{
           amount: inquiry.bill_amount,
           sheets: inquiry.sheets,
           customer_ref: inquiry.customer_ref,
           customer_name: inquiry.customer_name,
           customer_details: inquiry.details,
           period: inquiry.period,
           inquiry: inquiry
         }}
    end
  end

  defp bill_details(_channel, product, _store, attrs) do
    {:ok,
     %{
       amount: bill_amount(product, attrs),
       sheets: 1,
       customer_ref: nil,
       customer_name: nil,
       customer_details: nil,
       period: nil,
       inquiry: nil
     }}
  end

  defp lock_inquiry(id, store, product) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        now = now()

        Repo.one(
          from i in Inquiry,
            where:
              i.id == ^id and i.store_id == ^store.id and i.service_product_id == ^product.id and
                is_nil(i.used_at) and i.expires_at > ^now,
            lock: "FOR UPDATE"
        )

      _ ->
        nil
    end
  end

  defp use_inquiry(nil), do: :ok

  defp use_inquiry(%Inquiry{id: id}) do
    Repo.update_all(from(i in Inquiry, where: i.id == ^id), set: [used_at: now()])
    :ok
  end

  ## Sending (Fase 1)

  @doc """
  Sends an api service to its provider, once: only a `processing` api service
  with no `sent_at` is sent, and `sent_at` is committed before the call, so a
  crash afterwards leaves a service the status checker asks about instead of
  paying again. The answer goes through `apply_result/2`; a timeout or network
  error leaves it pending.
  """
  def send_payment(transaction_id) do
    case claim_for_sending(transaction_id) do
      {:ok, transaction, adapter, credentials, request} ->
        result =
          case adapter.pay(credentials, request) do
            {:ok, result} ->
              result

            {:error, _} ->
              %{status: :pending, provider_ref: nil, message: "Belum ada jawaban penyedia"}
          end

        apply_result(transaction.id, result)
        :ok

      {:no_provider, transaction} ->
        apply_result(transaction.id, %{
          status: :pending,
          provider_ref: nil,
          message: "Kredensial penyedia tidak bisa dibaca. Minta admin mengisinya ulang."
        })

        :ok

      :skip ->
        :ok
    end
  end

  defp claim_for_sending(transaction_id) do
    fn -> transaction_id |> lock_transaction() |> claim() end
    |> Repo.transaction()
    |> case do
      {:ok, claimed} -> claimed
      _ -> :skip
    end
  end

  # Inside claim_for_sending/1's transaction, on the locked row.
  defp claim(%Transaction{status: "processing", channel: "api", sent_at: nil} = transaction) do
    enter_store_organization(transaction)
    account = Deposits.get_account!(transaction.deposit_account_id)

    case Deposits.connection(account) do
      {:ok, adapter, credentials} ->
        {:ok, sent} = transaction |> Ecto.Changeset.change(sent_at: now()) |> Repo.update()
        {:ok, sent, adapter, credentials, provider_request(sent)}

      _ ->
        {:no_provider, transaction}
    end
  end

  defp claim(_transaction), do: :skip

  @doc false
  # What the provider is sent about a service (pay and status alike).
  def provider_request(%Transaction{} = transaction) do
    # Only a bill is paid against its inquiry; a token PLN's owner check is not.
    {inquiry_ref, months} =
      (transaction.service_inquiry_id &&
         Repo.one(
           from i in Inquiry,
             where: i.id == ^transaction.service_inquiry_id and i.kind == "bill",
             select: {i.inquiry_ref, i.months}
         )) || {nil, nil}

    %{
      ref_id: transaction.ref_id,
      product_code: transaction.provider_code || product_code(transaction),
      customer_ref: transaction.customer_ref,
      inquiry_ref: inquiry_ref,
      months: months
    }
  end

  # Services recorded before vendor codes were copied read the product's.
  defp product_code(%Transaction{service_product_id: id}),
    do: Repo.one(from p in Product, where: p.id == ^id, select: p.provider_code)

  # Background work has no user: the store says whose data this is.
  defp enter_store_organization(%Transaction{store_id: store_id}) do
    store = Repo.get!(Zahlungs.Stores.Store, store_id, skip_org_id: true)
    Repo.put_org_id(store.organization_id)
  end

  defp lock_transaction(id) do
    Repo.one(from t in Transaction, where: t.id == ^id, lock: "FOR UPDATE")
  end

  @doc """
  The one way an api service gets the provider's answer — from `pay`, a
  callback or a status check. Locks the row; only a `processing` service
  changes, so a late or repeated answer is `{:ok, :already_final}`.

  A failure on a shift already closed is flagged `failed_after_shift_close`:
  the closed shift's figures stay as they were (see `shift_totals/1`).

  An answer may also carry `actual_cost` (what the provider charged: it
  becomes `cost`, and marks the product's `provider_price` when above the
  product's cost) and `payload` (the raw answer, kept up to 4000 characters).
  `:refunded` on a processing service is a failure.

  An answer that contradicts a final status — a refund after success, or a
  success after failure — changes nothing but `review_reason`, for an admin to
  decide (`resolve_review/3`). Every change is broadcast to the store
  (`subscribe/1`).
  """
  def apply_result(transaction_id, result) do
    fn ->
      case lock_transaction(transaction_id) do
        %Transaction{status: "processing"} = transaction -> settle_result(transaction, result)
        %Transaction{} = transaction -> hold_contradiction(transaction, result)
        nil -> :already_final
      end
    end
    |> Repo.transaction()
    |> tap(fn
      {:ok, %Transaction{} = updated} -> broadcast(updated)
      _ -> :ok
    end)
  end

  defp settle_result(transaction, result) do
    {:ok, updated} =
      transaction
      |> Ecto.Changeset.change(result_changes(transaction, result))
      |> Ecto.Changeset.change(answer_copies(result))
      |> Repo.update()

    note_vendor_price(updated, result)
    updated
  end

  defp answer_copies(result) do
    %{
      cost: Map.get(result, :actual_cost),
      provider_payload: clip(Map.get(result, :payload), 4000)
    }
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
  end

  # The provider charges more than the product's cost: the admin should see it.
  defp note_vendor_price(%Transaction{service_product_id: id}, %{actual_cost: %Decimal{} = cost}) do
    Repo.update_all(
      # A bill's actual cost is the whole bill, not comparable with its fee.
      from(p in Product, where: p.id == ^id and p.category != "tagihan" and p.cost < ^cost),
      [set: [provider_price: cost, provider_checked_at: now()]],
      skip_org_id: true
    )
  end

  defp note_vendor_price(_transaction, _result), do: :ok

  defp hold_contradiction(
         %Transaction{status: "success"} = transaction,
         %{status: :refunded} = r
       ),
       do: hold(transaction, "Penyedia melaporkan refund: " <> (Map.get(r, :message) || "-"))

  defp hold_contradiction(%Transaction{status: "success"} = transaction, %{status: :failed} = r),
    do:
      hold(
        transaction,
        "Penyedia melaporkan gagal setelah berhasil: " <> (Map.get(r, :message) || "-")
      )

  # The token/SN comes along, for the admin who decides it was a success.
  defp hold_contradiction(%Transaction{status: "failed"} = transaction, %{status: :success} = r) do
    hold(transaction, "Penyedia melaporkan berhasil setelah transaksi gagal", %{
      token_sn: r |> Map.get(:token_sn) |> clip(64),
      provider_ref: clip(Map.get(r, :provider_ref), 255) || transaction.provider_ref
    })
  end

  defp hold_contradiction(_transaction, _result), do: :already_final

  defp hold(transaction, reason, changes \\ %{}) do
    {:ok, held} =
      transaction
      |> Ecto.Changeset.change(Map.put(changes, :review_reason, clip(reason, 255)))
      |> Repo.update()

    held
  end

  defp result_changes(transaction, %{status: :refunded} = result),
    do: result_changes(transaction, %{result | status: :failed})

  defp result_changes(_transaction, %{status: :success} = result) do
    %{
      status: "success",
      token_sn: result |> Map.get(:token_sn) |> clip(64),
      provider_ref: result |> Map.get(:provider_ref) |> clip(255),
      provider_message: nil,
      resolved_at: now(),
      last_checked_at: now()
    }
  end

  defp result_changes(transaction, %{status: :failed} = result) do
    %{
      status: "failed",
      provider_message: result |> Map.get(:message, "Gagal di penyedia") |> clip(255),
      resolved_at: now(),
      last_checked_at: now(),
      failed_after_shift_close: shift_closed?(transaction)
    }
  end

  defp result_changes(transaction, %{status: :pending} = result) do
    %{
      provider_ref: clip(Map.get(result, :provider_ref), 255) || transaction.provider_ref,
      provider_message: clip(Map.get(result, :message), 255) || transaction.provider_message,
      last_checked_at: now()
    }
  end

  defp shift_closed?(%Transaction{shift_id: shift_id}) do
    Repo.exists?(from s in Shift, where: s.id == ^shift_id and s.status == "closed")
  end

  defp clip(nil, _max), do: nil
  defp clip(value, max), do: value |> to_string() |> String.slice(0, max)

  ## Status checks (Fase 1)

  @recheck_after 30

  @doc """
  Asks the provider how an api service is doing, now (the cashier's "Cek
  status", and the status checker). A service never sent is sent instead,
  once. A provider that doesn't know the `ref_id` leaves it pending, with a
  message to look it up in the provider's own app — it is never paid again.
  """
  def check_status(transaction_id) do
    case Repo.get(Transaction, transaction_id) do
      %Transaction{status: "processing", channel: "api", sent_at: nil} = transaction ->
        send_payment(transaction.id)
        {:ok, Repo.get!(Transaction, transaction.id)}

      %Transaction{status: "processing", channel: "api"} = transaction ->
        ask_status(transaction)

      _ ->
        {:ok, :already_final}
    end
  end

  defp ask_status(transaction) do
    enter_store_organization(transaction)
    account = Deposits.get_account!(transaction.deposit_account_id)

    result =
      with {:ok, adapter, credentials} <- Deposits.connection(account),
           {:ok, result} <- adapter.status(credentials, provider_request(transaction)) do
        result
      else
        {:error, :not_found} ->
          %{
            status: :pending,
            message: "Penyedia tidak mengenal transaksi ini. Periksa di aplikasi penyedia."
          }

        {:error, :credentials} ->
          %{
            status: :pending,
            message: "Kredensial penyedia tidak bisa dibaca. Minta admin mengisinya ulang."
          }

        {:error, _} ->
          %{status: :pending, message: "Belum ada jawaban penyedia"}
      end

    apply_result(transaction.id, result)
  end

  @doc """
  One round of the status checker: every api service still processing, in
  any store or organization, that was never sent (sent now) or not asked about
  in the last #{@recheck_after} seconds (asked now). Returns how many it handled.
  """
  def check_pending(now \\ NaiveDateTime.utc_now()) do
    due = NaiveDateTime.add(now, -@recheck_after)

    ids =
      Repo.all(
        from t in Transaction,
          where:
            t.channel == "api" and t.status == "processing" and
              (is_nil(t.sent_at) or coalesce(t.last_checked_at, t.sent_at) < ^due),
          order_by: t.id,
          select: t.id
      )

    Enum.each(ids, &check_one/1)
    length(ids)
  end

  # A service that raises (an adapter meeting an answer it doesn't expect) is
  # logged and tried again next round; the others are still checked.
  defp check_one(id) do
    check_status(id)
  rescue
    error ->
      Logger.error("Status check of service #{id} failed: " <> Exception.message(error))
  end

  ## Callbacks (Fase 1)

  @doc """
  A provider's callback for the account with `token`: the adapter checks the
  signature with the account's credentials, the `ref_id` must be an api
  service of that account, and the result goes through `apply_result/2` — so a
  repeated or late callback changes nothing.

  Returns `{:ok, :applied | :already_final}` or
  `{:error, :unknown_account | :invalid_signature | :unknown_ref}`.
  """
  def handle_callback(token, params, headers) do
    with {:ok, account} <- callback_account(token),
         {:ok, ref_id, result} <- verify_callback(account, params, headers),
         {:ok, transaction} <- account_transaction(account, ref_id) do
      case apply_result(transaction.id, result) do
        {:ok, %Transaction{}} -> {:ok, :applied}
        {:ok, :already_final} -> {:ok, :already_final}
      end
    end
  end

  @doc """
  A provider's callback without a token in the URL (Smart Biller
  Indonesia's): each adapter with `callback_ref/1` reads the ref from `params`;
  it must name an api service whose account uses that adapter; then the
  adapter checks the caller with that account's credentials, and the result
  goes through `apply_result/2`. Refs are unique across organizations, so the
  service is looked up in all of them, and its store's organization entered.

  Returns `{:ok, :applied | :already_final}` or
  `{:error, :unknown_ref | :invalid_signature}`.
  """
  def handle_ref_callback(params, headers) do
    Enum.find_value(ref_readers(), {:error, :unknown_ref}, fn {key, adapter} ->
      with {:ok, ref_id} <- adapter.callback_ref(params),
           {:ok, transaction, account} <- ref_transaction(ref_id, key) do
        settle_callback(transaction, account, params, headers)
      else
        _ -> nil
      end
    end)
  end

  defp ref_readers do
    for {key, adapter} <- Provider.adapters(),
        Code.ensure_loaded?(adapter) and function_exported?(adapter, :callback_ref, 1),
        do: {key, adapter}
  end

  defp ref_transaction(ref_id, adapter_key) when is_binary(ref_id) do
    with %Transaction{} = transaction <-
           Repo.one(from t in Transaction, where: t.ref_id == ^ref_id and t.channel == "api"),
         _ = enter_store_organization(transaction),
         %Deposits.Account{provider: ^adapter_key} = account <-
           Deposits.get_account!(transaction.deposit_account_id) do
      {:ok, transaction, account}
    else
      _ -> :error
    end
  end

  defp settle_callback(transaction, account, params, headers) do
    case verify_callback(account, params, headers) do
      {:ok, ref_id, result} when ref_id == transaction.ref_id ->
        case apply_result(transaction.id, result) do
          {:ok, %Transaction{}} -> {:ok, :applied}
          {:ok, :already_final} -> {:ok, :already_final}
        end

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp callback_account(token) do
    case Deposits.get_account_by_callback_token(token) do
      nil ->
        {:error, :unknown_account}

      account ->
        Repo.put_org_id(account.organization_id)
        {:ok, account}
    end
  end

  # Credentials that can't be read can't vouch for a signature either.
  defp verify_callback(account, params, headers) do
    case Deposits.connection(account) do
      {:ok, adapter, credentials} -> adapter.verify_callback(credentials, params, headers)
      {:error, :credentials} -> {:error, :invalid_signature}
    end
  end

  defp account_transaction(account, ref_id) when is_binary(ref_id) do
    case Repo.one(
           from t in Transaction,
             where:
               t.ref_id == ^ref_id and t.deposit_account_id == ^account.id and t.channel == "api"
         ) do
      nil -> {:error, :unknown_ref}
      transaction -> {:ok, transaction}
    end
  end

  defp account_transaction(_account, _ref_id), do: {:error, :unknown_ref}

  @doc "Subscribes to `{:service_changed, transaction_id}` for a store's services."
  def subscribe(store_id), do: Phoenix.PubSub.subscribe(Zahlungs.PubSub, topic(store_id))

  defp broadcast(%Transaction{id: id, store_id: store_id}) do
    Phoenix.PubSub.broadcast(Zahlungs.PubSub, topic(store_id), {:service_changed, id})
  end

  defp topic(store_id), do: "services:store:#{store_id}"

  ## Results

  @doc """
  Marks a processing service done, with the token or serial number from the
  provider's app (optional). See `mark_failed/3` for who may mark and what is
  refused.
  """
  def mark_success(%Transaction{} = transaction, %User{} = user, token_sn) do
    resolve(transaction, user, %{status: "success", token_sn: token_sn})
  end

  @doc """
  Marks a processing service failed; the reason is required and the money goes
  back to the customer.

  Only the cashier who recorded it, or an admin, may mark a service. The row is
  locked and its status read from the database, so a stale struct (another tab)
  can't mark it a second time. Returns `{:ok, transaction}` or
  `{:error, :forbidden | :not_processing | changeset}`.
  """
  def mark_failed(%Transaction{} = transaction, %User{} = user, reason) do
    resolve(transaction, user, %{status: "failed", failure_reason: reason})
  end

  defp resolve(%Transaction{id: id}, user, attrs) do
    Repo.transaction(fn ->
      locked = Repo.one!(from t in Transaction, where: t.id == ^id, lock: "FOR UPDATE")

      case apply_mark(locked, user, attrs) do
        {:ok, transaction} -> transaction
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # `locked` is the row as the database has it, under its lock.
  defp apply_mark(locked, user, attrs) do
    cond do
      locked.channel == "api" and not (user.role == "admin" and awaiting_too_long?(locked)) ->
        {:error, :not_manual}

      locked.user_id != user.id and user.role != "admin" ->
        {:error, :forbidden}

      locked.status != "processing" ->
        {:error, :not_processing}

      true ->
        locked
        |> Transaction.resolve_changeset(attrs)
        |> Ecto.Changeset.change(resolved_by_id: user.id, resolved_at: now())
        |> Repo.update()
    end
  end

  @settle_by_hand_after 10 * 60

  @doc """
  Whether an api service has waited for the provider so long (#{div(@settle_by_hand_after, 60)}
  minutes since it was recorded) that an admin may mark it by hand, after
  looking it up in the provider's own app. A failure marked so goes to "Perlu
  dikembalikan" like any other.
  """
  def awaiting_too_long?(transaction, now \\ NaiveDateTime.utc_now())

  def awaiting_too_long?(%Transaction{channel: "api", status: "processing"} = transaction, now),
    do: NaiveDateTime.diff(now, transaction.inserted_at) >= @settle_by_hand_after

  def awaiting_too_long?(_transaction, _now), do: false

  ## Brand prefixes

  @doc """
  The mobile number prefixes of each brand, as `%{brand => [prefix]}` with
  every brand of `Brand.keys/0` (an empty list for one without), each list in
  order. Kept by the platform operator for every organization.
  """
  def brand_prefixes do
    empty = Map.new(Brand.keys(), &{&1, []})

    from(p in BrandPrefix, order_by: [desc: p.prefix], select: {p.brand, p.prefix})
    |> Repo.all()
    |> Enum.reduce(empty, fn {brand, prefix}, acc ->
      if Map.has_key?(acc, brand), do: Map.update!(acc, brand, &[prefix | &1]), else: acc
    end)
  end

  @doc """
  Replaces every brand's prefixes with the ones typed in `params`
  (`%{brand => "0811, 0812"}`, separated by commas, semicolons or spaces); a
  brand left out has none. Each prefix is four digits starting with `08` and
  belongs to one brand. `{:error, %{brand => message}}` saves nothing.
  """
  def save_brand_prefixes(params) when is_map(params) do
    prefixes = Map.new(Brand.keys(), &{&1, parse_prefixes(params[&1])})
    errors = prefix_errors(prefixes)

    if errors == %{}, do: replace_prefixes(prefixes), else: {:error, errors}
  end

  @doc "Puts the default prefixes (`Brand.default_prefixes/0`) back."
  def reset_brand_prefixes do
    defaults = Brand.default_prefixes()
    replace_prefixes(Map.new(Brand.keys(), &{&1, Map.get(defaults, &1, [])}))
  end

  defp parse_prefixes(text) when is_binary(text) do
    text |> String.split(~r/[\s,;]+/, trim: true) |> Enum.uniq() |> Enum.sort()
  end

  defp parse_prefixes(_text), do: []

  defp prefix_errors(prefixes) do
    owners =
      for {brand, list} <- prefixes, prefix <- list, reduce: %{} do
        acc -> Map.update(acc, prefix, [brand], &(&1 ++ [brand]))
      end

    for {brand, list} <- prefixes,
        message = prefix_message(brand, list, owners),
        into: %{},
        do: {brand, message}
  end

  defp prefix_message(brand, list, owners) do
    wrong = Enum.reject(list, &Regex.match?(~r/\A08\d{2}\z/, &1))

    shared =
      for prefix <- list, others = owners[prefix] -- [brand], others != [] do
        "#{prefix} juga ada di #{Enum.map_join(others, ", ", &Brand.label/1)}."
      end

    wrong_message = if wrong != [], do: ["Bukan awalan 4 angka 08xx: #{Enum.join(wrong, ", ")}."]

    case (wrong_message || []) ++ shared do
      [] -> nil
      messages -> Enum.join(messages, " ")
    end
  end

  defp replace_prefixes(prefixes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for {brand, list} <- prefixes, prefix <- list do
        %{brand: brand, prefix: prefix, inserted_at: now, updated_at: now}
      end

    Repo.transaction(fn ->
      Repo.delete_all(BrandPrefix)
      Repo.insert_all(BrandPrefix, rows)
      brand_prefixes()
    end)
  end

  ## Vendor catalog

  @catalog_results 30

  @doc """
  The organization's first active api deposit account whose provider has a
  catalog (`Provider` `catalog/1`), or `nil`.
  """
  def catalog_account do
    Enum.find(Deposits.list_active_accounts(), &(Deposits.api?(&1) and catalog_adapter(&1)))
  end

  defp catalog_adapter(%Deposits.Account{provider: key}) do
    case Provider.adapter(key) do
      {:ok, adapter} ->
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :catalog, 1),
          do: adapter

      :error ->
        nil
    end
  end

  @doc """
  The provider's products whose name or code holds every word of `query`
  (case aside), at most #{@catalog_results}. The catalog is kept in memory for a while
  (`Zahlungs.Services.CatalogCache`), never stored.
  """
  def search_catalog(%Deposits.Account{} = account, query) do
    words = query |> to_string() |> String.downcase() |> String.split(~r/\s+/, trim: true)

    with adapter when adapter != nil <- catalog_adapter(account),
         {:ok, items} <- CatalogCache.fetch(account.provider, fn -> adapter.catalog([]) end) do
      {:ok, items |> Enum.filter(&catalog_match?(&1, words)) |> Enum.take(@catalog_results)}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp catalog_match?(item, words) do
    text = String.downcase("#{item.name} #{item.code}")
    Enum.all?(words, &String.contains?(text, &1))
  end

  @doc """
  What refreshing the products from the provider would change, saving
  nothing: for each product with a vendor code the provider answered about,
  `%{product, old_cost, new_cost, new_price, vendor_price, status}`. A bill's
  cost isn't the vendor's price, so only its status changes.
  """
  def price_update(%Deposits.Account{} = account) do
    products = Enum.reject(list_products(), &blank_code?/1)
    codes = products |> Enum.map(& &1.provider_code) |> Enum.uniq()

    with {:ok, adapter, credentials} <- Deposits.provider(account),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :prices, 2),
         {:ok, prices} <- adapter.prices(credentials, codes) do
      rows =
        for product <- products,
            info = prices[product.provider_code],
            info != nil,
            do: price_row(product, info)

      {:ok, rows}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp price_row(product, info) do
    new_cost =
      if Product.bill?(product) or is_nil(info.price), do: product.cost, else: info.price

    new_price =
      case price_for(%{product | cost: new_cost}, nil) do
        {:ok, %{price: price}} -> price
        {:error, _bill} -> nil
      end

    %{
      product: product,
      old_cost: product.cost,
      new_cost: new_cost,
      new_price: new_price,
      vendor_price: info.price,
      status: info.status
    }
  end

  @doc "Saves the rows of `price_update/1`, in one transaction. Returns `{:ok, count}`."
  def apply_price_update(%Deposits.Account{}, rows) do
    checked_at = now()

    Repo.transaction(fn ->
      Enum.each(rows, fn row ->
        row.product
        |> Ecto.Changeset.change(
          cost: row.new_cost,
          provider_price: row.vendor_price,
          provider_status: row.status,
          provider_checked_at: checked_at
        )
        |> Repo.update!()
      end)

      length(rows)
    end)
  end

  ## Reviews

  @doc """
  An admin decides about an answer that contradicted a final status (see
  `apply_result/2`). `:keep` leaves the status and drops the flag; `:refund`
  (a success the provider took back) fails it, so its money waits under
  "Perlu dikembalikan" and stops counting against the deposit; `:success` (a
  failure the provider says went through, not refunded yet) makes it a
  success, counting against the deposit again. Locks the row. While in review
  a failure is not refunded (`confirm_refund/2` → `{:error, :in_review}`).

  Returns `{:ok, transaction}` or `{:error, :forbidden | :not_in_review}`.
  """
  def resolve_review(%Transaction{id: id}, %User{role: "admin"} = admin, decision)
      when decision in [:keep, :refund, :success] do
    fn ->
      case review(lock_transaction(id), admin, decision) do
        {:ok, transaction} -> transaction
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> tap(fn
      {:ok, transaction} -> broadcast(transaction)
      _ -> :ok
    end)
  end

  def resolve_review(%Transaction{}, %User{}, _decision), do: {:error, :forbidden}

  defp review(%Transaction{review_reason: reason} = transaction, admin, :keep)
       when is_binary(reason) do
    transaction |> reviewed(admin) |> Repo.update()
  end

  defp review(
         %Transaction{status: "success", review_reason: reason} = transaction,
         admin,
         :refund
       )
       when is_binary(reason) do
    transaction
    |> reviewed(admin)
    |> Ecto.Changeset.change(
      status: "failed",
      failure_reason: reason,
      resolved_at: now(),
      failed_after_shift_close: shift_closed?(transaction)
    )
    |> Repo.update()
  end

  defp review(
         %Transaction{status: "failed", refunded_at: nil, review_reason: reason} = transaction,
         admin,
         :success
       )
       when is_binary(reason) do
    transaction
    |> reviewed(admin)
    |> Ecto.Changeset.change(
      status: "success",
      failure_reason: nil,
      provider_message: nil,
      failed_after_shift_close: false,
      resolved_at: now()
    )
    |> Repo.update()
  end

  defp review(_transaction, _admin, _decision), do: {:error, :not_in_review}

  defp reviewed(transaction, admin) do
    Ecto.Changeset.change(transaction,
      review_reason: nil,
      reviewed_at: now(),
      reviewed_by_id: admin.id
    )
  end

  @doc "A service of a deposit account; another account's raises `Ecto.NoResultsError`."
  def get_account_transaction!(%Deposits.Account{id: account_id}, id) do
    Repo.one!(from t in Transaction, where: t.id == ^id and t.deposit_account_id == ^account_id)
  end

  @doc "The services of a deposit account waiting for an admin's review, newest first."
  def list_in_review(%Deposits.Account{id: account_id}) do
    Repo.all(
      from t in Transaction,
        where: t.deposit_account_id == ^account_id and not is_nil(t.review_reason),
        order_by: [desc: t.updated_at, desc: t.id]
    )
  end

  ## Reading

  @doc "Gets a service of the scope's store(s); another store's raises `Ecto.NoResultsError`."
  def get_transaction!(%Scope{} = scope, id) do
    Repo.one!(
      from t in for_store(Transaction, scope), where: t.id == ^id, preload: [:store, :user]
    )
  end

  @doc "The services recorded on a shift, newest first."
  def list_shift_transactions(%Shift{id: shift_id}) do
    Repo.all(
      from t in Transaction,
        where: t.shift_id == ^shift_id,
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  @doc """
  What a shift's services add up to: `count`, `total` and `cash_total` (the
  cash that went into the drawer). Processing and successful services count —
  the money was taken. A failed manual service doesn't — it was handed back
  when marked. A failed api service counts until its refund is confirmed from
  this shift's drawer; one refunded from another drawer (a later shift, a
  colleague's) keeps counting here, flagged `failed_after_shift_close`, and is
  a `refund` cash-out there (see `confirm_refund/2`).
  """
  def shift_totals(%Shift{id: shift_id}) do
    row =
      Repo.one(
        from t in Transaction,
          where:
            t.shift_id == ^shift_id and
              (t.status in ["processing", "success"] or
                 (t.status == "failed" and
                    (t.failed_after_shift_close or
                       (t.channel == "api" and is_nil(t.refunded_at))))),
          select: %{
            count: count(t.id),
            total: coalesce(sum(t.price), 0),
            cash_total:
              coalesce(
                sum(
                  fragment("CASE WHEN ? = 'cash' THEN ? ELSE 0 END", t.payment_method, t.price)
                ),
                0
              )
          }
      )

    %{count: row.count, total: to_decimal(row.total), cash_total: to_decimal(row.cash_total)}
  end

  @doc """
  What services have taken out of a deposit account: the cost of those
  processing (the provider has charged) and successful. Failed ones are
  refunded by the provider and don't count.
  """
  def deposit_used(%Zahlungs.Deposits.Account{id: account_id}) do
    from(t in Transaction,
      where: t.deposit_account_id == ^account_id and t.status in ["processing", "success"],
      select: coalesce(sum(t.cost), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  ## Report

  @doc """
  The services of the scope's store(s) between two shop-local dates
  (inclusive): how many succeeded and failed, and for the successful ones the
  value (what customers paid), the cost and the margin — in total and per
  category.
  """
  def report(%Scope{} = scope, %Date{} = date_from, %Date{} = date_to) do
    {start, finish} = LocalTime.day_range(date_from, date_to, scope.store)

    in_range =
      from t in for_store(Transaction, scope),
        where: t.inserted_at >= ^start and t.inserted_at <= ^finish

    by_category =
      Repo.all(
        from t in in_range,
          where: t.status == "success",
          group_by: t.category,
          order_by: t.category,
          select: %{
            category: t.category,
            count: count(t.id),
            value: coalesce(sum(t.price), 0),
            cost: coalesce(sum(t.cost), 0)
          }
      )
      |> Enum.map(fn row ->
        value = to_decimal(row.value)
        cost = to_decimal(row.cost)
        %{row | value: value, cost: cost} |> Map.put(:margin, Decimal.sub(value, cost))
      end)

    value = sum_of(by_category, :value)
    cost = sum_of(by_category, :cost)

    %{
      success_count: Enum.sum(Enum.map(by_category, & &1.count)),
      failed_count: Repo.aggregate(where(in_range, [t], t.status == "failed"), :count),
      value: value,
      cost: cost,
      margin: Decimal.sub(value, cost),
      by_category: by_category
    }
  end

  defp sum_of(rows, key),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, Map.fetch!(&1, key)))

  @doc """
  How many manual services of a shift are still processing: those hold the
  shift open (an api service pending at the provider doesn't).
  """
  def count_blocking_close(%Shift{id: shift_id}) do
    Repo.aggregate(
      from(t in Transaction,
        where: t.shift_id == ^shift_id and t.status == "processing" and t.channel == "manual"
      ),
      :count
    )
  end

  ## Refunds (Fase 1)

  @doc "Failed api services of the scope's store(s) whose money hasn't been handed back yet."
  def list_refunds_due(%Scope{} = scope) do
    Repo.all(
      from t in for_store(Transaction, scope),
        where:
          t.channel == "api" and t.status == "failed" and is_nil(t.refunded_at) and
            is_nil(t.review_reason),
        order_by: [desc: t.resolved_at, desc: t.id]
    )
  end

  @doc """
  A cashier confirms the money of a failed api service went back to the
  customer, on their open shift in the service's store. Cash refunded on the
  service's own shift simply leaves that drawer (the shift stops counting it).
  Cash refunded on any other shift — a later one, or a colleague's — is booked
  as a `refund` cash-out there, and the service keeps counting in its own
  shift (`failed_after_shift_close`). Non-cash is refunded the way it was
  paid, never from a drawer.

  Returns `{:ok, transaction}` or
  `{:error, :not_refundable | :in_review | :no_open_shift | :other_store}`.
  """
  def confirm_refund(%Transaction{id: id}, %User{} = user) do
    Repo.put_org_id(user.organization_id)

    fn ->
      case refund(lock_transaction(id), user) do
        {:ok, transaction} -> transaction
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> tap(fn
      {:ok, transaction} -> broadcast(transaction)
      _ -> :ok
    end)
  end

  # The provider may have served it after all: an admin decides first.
  defp refund(%Transaction{review_reason: reason}, _user) when is_binary(reason),
    do: {:error, :in_review}

  defp refund(
         %Transaction{channel: "api", status: "failed", refunded_at: nil} = transaction,
         user
       ) do
    with {:ok, shift} <- Shifts.lock_current_shift(user),
         :ok <- same_store(shift, transaction),
         {:ok, changes} <- refund_from_drawer(shift, transaction) do
      transaction
      |> Ecto.Changeset.change([refunded_at: now(), refunded_by_id: user.id] ++ changes)
      |> Repo.update()
    end
  end

  defp refund(_transaction, _user), do: {:error, :not_refundable}

  defp same_store(%Shift{store_id: store_id}, %Transaction{store_id: store_id}), do: :ok
  defp same_store(_shift, _transaction), do: {:error, :other_store}

  defp refund_from_drawer(%Shift{id: shift_id}, %Transaction{shift_id: shift_id}), do: {:ok, []}

  defp refund_from_drawer(shift, %Transaction{payment_method: "cash"} = transaction) do
    case Shifts.add_cash_movement(shift, %{
           category: "refund",
           amount: transaction.price,
           note: "Refund #{transaction.code}"
         }) do
      {:ok, _movement} -> {:ok, [failed_after_shift_close: true]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refund_from_drawer(_shift, _transaction), do: {:ok, []}

  @doc "How many services of a shift are still processing."
  def count_processing(%Shift{id: shift_id}) do
    Repo.aggregate(
      from(t in Transaction, where: t.shift_id == ^shift_id and t.status == "processing"),
      :count
    )
  end

  defp for_store(query, scope) do
    case Scope.store_id(scope) do
      nil -> where(query, [t], t.store_id in ^Stores.store_ids())
      store_id -> where(query, [t], t.store_id == ^store_id)
    end
  end

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

  defp store_account(%{deposit_account_id: id}) do
    case Deposits.get_active_account(id) do
      nil -> {:error, :no_deposit_account}
      account -> {:ok, account}
    end
  end

  # Active and not deleted: a screen left open may still offer one that isn't.
  defp sellable_product(id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Product{} = product <-
           Repo.one(
             from p in Product,
               where: p.id == ^id and p.active == true and is_nil(p.deleted_at)
           ) do
      {:ok, product}
    else
      _ -> {:error, :product_unavailable}
    end
  end

  # A price changed while the screen was open must not be charged silently: the
  # cashier quoted, and gave change for, the old one.
  defp check_quoted_price(quoted, _price) when quoted in [nil, ""], do: :ok

  defp check_quoted_price(quoted, price) do
    if Decimal.equal?(to_decimal(quoted), price), do: :ok, else: {:error, :price_changed}
  end

  defp bill_amount(product, attrs) do
    if Product.bill?(product), do: to_decimal(attrs["bill_amount"])
  end

  # Cash must cover the price and may produce change; other methods are paid
  # for the exact price.
  defp settle(attrs, price) do
    case attrs["payment_method"] do
      method when method in [nil, "", "cash"] ->
        paid = to_decimal(attrs["amount_paid"])

        if Decimal.lt?(paid, price),
          do: {:error, :insufficient_payment},
          else: {:ok, %{method: "cash", amount_paid: paid, change_due: Decimal.sub(paid, price)}}

      method ->
        {:ok, %{method: method, amount_paid: price, change_due: Decimal.new(0)}}
    end
  end

  # Store code + LYN + store-local timestamp + random hex, like a sale's INV code.
  defp generate_code(store) do
    ts = Calendar.strftime(LocalTime.now(store), "%y%m%d%H%M%S")
    "#{store.code}-LYN#{ts}#{Base.encode16(:crypto.strong_rand_bytes(2))}"
  end

  # A bill's admin fee is per sheet (month); a percent is of the whole bill.
  defp bill_margin(%Product{margin_type: "percent"} = product, bill, _sheets),
    do: margin(product, bill)

  defp bill_margin(%Product{margin_value: fee}, _bill, sheets), do: Decimal.mult(fee, sheets)

  defp margin(%Product{margin_type: "percent", margin_value: percent}, base) do
    base |> Decimal.mult(percent) |> Decimal.div(100) |> Decimal.round(0, :ceiling)
  end

  defp margin(%Product{margin_value: amount}, _base), do: amount

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)

  defp to_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {d, ""} -> d
      _ -> Decimal.new(0)
    end
  end
end
