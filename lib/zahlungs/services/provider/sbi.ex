defmodule Zahlungs.Services.Provider.Sbi do
  @moduledoc """
  Smart Biller Indonesia (SBI) through its JSON API with signed requests
  (`Sbi.Sign`), answers read by `Sbi.Reply`. HTTP goes through the client in
  `config :zahlungs, Zahlungs.Services.Provider.Sbi, client:` — `Sbi.Client`,
  or `Sbi.StubClient` in tests, which never reach SBI.

  | Zahlungs | SBI action |
  | --- | --- |
  | Cek tagihan / cek pelanggan token | `inquiry` (a meter's owner: the product's check code, default `CPLNPRA`) |
  | Bayar tagihan | `payment` with the inquiry's `ref_1` and `ref_2` |
  | Pulsa, paket data, token PLN | `topup` |
  | Cek status | `status` |
  | Tes koneksi, Ambil saldo | `balance` |
  | Perbarui dari SBI | `price` per code |

  No answer, a server error or a page that isn't JSON on `pay` is
  `{:error, :timeout}`: the service stays pending. `status` gives a result only
  from SBI's `data`; an error answer there is `{:error, :not_found}` (pending,
  never a failure).
  """
  @behaviour Zahlungs.Services.Provider

  alias Zahlungs.Services.Provider.Sbi.{Reply, Sign}

  @inquiry_timeout 15_000
  @pay_timeout 45_000
  @status_timeout 15_000
  @owner_code "CPLNPRA"

  @impl true
  def credential_fields,
    do: [{"member_id", "Member ID"}, {"pin", "PIN"}, {"password", "Password"}]

  # The member ID names the account; the PIN and the password are the secrets.
  @impl true
  def public_credentials, do: ["member_id"]

  @impl true
  def inquiry(credentials, %{ref_id: ref_id, customer_ref: number, kind: kind} = request) do
    body =
      %{
        "ref_1" => ref_id,
        "product_code" => inquiry_code(kind, request),
        "customer_id" => number
      }
      |> put_periode(request)

    case call(credentials, "inquiry", body, @inquiry_timeout) do
      {:ok, status, answer} -> Reply.inquiry(Reply.envelope(status, answer), kind)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # A bill is asked about with its own code. A meter's owner with the
  # product's check code, or SBI's default (not in every member's price plan).
  defp inquiry_code(:customer, request) do
    case Map.get(request, :check_code) do
      code when is_binary(code) and code != "" -> String.trim(code)
      _ -> @owner_code
    end
  end

  defp inquiry_code(_bill, request), do: request.product_code

  @impl true
  def pay(credentials, %{ref_id: ref_id, product_code: code, customer_ref: number} = request) do
    body = %{"ref_1" => ref_id, "product_code" => code, "customer_id" => number}

    {action, body} =
      case Map.get(request, :inquiry_ref) do
        nil -> {"topup", body}
        ref_2 -> {"payment", body |> Map.put("ref_2", ref_2) |> put_periode(request)}
      end

    credentials |> call(action, body, @pay_timeout) |> transaction_answer()
  end

  # The months of a bill that asks for them (BPJS), as text. Not one of the
  # fields SBI signs (`call/4`), and never sent on a topup or a status check.
  defp put_periode(body, request) do
    case Map.get(request, :months) do
      months when is_integer(months) and months > 0 ->
        Map.put(body, "periode", Integer.to_string(months))

      _ ->
        body
    end
  end

  @impl true
  def status(credentials, %{ref_id: ref_id}) do
    case call(credentials, "status", %{"ref_1" => ref_id}, @status_timeout) do
      {:ok, status, answer} ->
        case Reply.envelope(status, answer) do
          {:data, data} -> Reply.transaction(data)
          {:rc, _code, _message} -> {:error, :not_found}
          :unknown -> {:error, :timeout}
        end

      {:error, _reason} ->
        {:error, :timeout}
    end
  end

  defp transaction_answer({:ok, status, answer}) do
    case Reply.envelope(status, answer) do
      {:data, data} -> Reply.transaction(data)
      {:rc, code, message} -> {:ok, Map.put(Reply.rc(code, message), :payload, message)}
      :unknown -> {:error, :timeout}
    end
  end

  defp transaction_answer({:error, _reason}), do: {:error, :timeout}

  @doc """
  SBI signs nothing in a callback: it sends the member's password in `rqid`,
  from its own address (`callback_ips`). Both must hold.
  """
  @impl true
  def verify_callback(credentials, params, headers) do
    password = credentials["password"] || ""
    rqid = headers["rqid"] || ""
    ips = Keyword.get(config(), :callback_ips, [])

    with true <- password != "" and Plug.Crypto.secure_compare(rqid, password),
         true <- headers["x-zahlungs-client-ip"] in ips,
         {:ok, ref_id} <- callback_ref(params),
         {:ok, result} <- Reply.transaction(params) do
      {:ok, ref_id, result}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @impl true
  def callback_ref(%{"ref_1" => ref_1}) when is_binary(ref_1) and ref_1 != "", do: {:ok, ref_1}
  def callback_ref(_params), do: :error

  @impl true
  def ping(credentials) do
    case balance(credentials) do
      {:ok, _balance} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @impl true
  def balance(credentials) do
    case call(credentials, "balance", %{}, @status_timeout) do
      {:ok, status, answer} ->
        case Reply.envelope(status, answer) do
          {:data, %{"saldo" => saldo}} -> balance_of(saldo)
          {:rc, _code, message} -> {:error, message}
          _ -> {:error, "Jawaban SBI tidak dikenal."}
        end

      {:error, _reason} ->
        {:error, "SBI tidak menjawab."}
    end
  end

  defp balance_of(saldo) do
    case Reply.money(saldo) do
      nil -> {:error, "Jawaban SBI tidak dikenal."}
      balance -> {:ok, balance}
    end
  end

  @doc """
  SBI's public price list (no credentials), as catalog items. The category is
  guessed from SBI's group: Pulsa Reguler → pulsa, `* Data` → paket_data, PLN
  Prabayar → token_pln, PPOB (every bill) → tagihan.
  """
  @impl true
  def catalog(_config) do
    case client().get_json(Keyword.fetch!(config(), :pricelist_url), 30_000) do
      {:ok, 200, %{} = groups} ->
        {:ok,
         for {group, items} <- groups, is_list(items), %{} = item <- items do
           catalog_item(group, item)
         end}

      _ ->
        {:error, :unavailable}
    end
  end

  defp catalog_item(group, item) do
    code = Reply.text(item["code"])

    %{
      code: code,
      name: Reply.text(item["name"]) || code,
      category_hint: category_hint(group, code),
      price: Reply.money(item["harga"]),
      admin: Reply.money(item["admin_amount"]),
      commission: Reply.money(item["komisi"]),
      status:
        cond do
          item["gangguan"] == "Ya" -> "gangguan"
          item["tersedia"] == "Tidak" -> "kosong"
          true -> "normal"
        end
    }
  end

  defp category_hint("Pulsa Reguler", _code), do: "pulsa"
  defp category_hint("PLN Prabayar", _code), do: "token_pln"
  defp category_hint("PPOB", _code), do: "tagihan"

  defp category_hint(group, _code) do
    if String.ends_with?(group, "Data"), do: "paket_data"
  end

  @doc """
  The member's price and status for each vendor code, at most five requests
  at a time (`opts[:max_concurrency]`). A code SBI doesn't know (RC:97/89) is
  `"tidak_ditemukan"`; one that got no answer is left out.
  """
  @impl true
  def prices(credentials, codes, opts \\ []) do
    prices =
      codes
      |> Task.async_stream(&{&1, price(credentials, &1)},
        max_concurrency: Keyword.get(opts, :max_concurrency, 5),
        timeout: @status_timeout + 1_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {code, %{} = price}} -> [{code, price}]
        _ -> []
      end)
      |> Map.new()

    {:ok, prices}
  end

  defp price(credentials, code) do
    case call(credentials, "price", %{"product_code" => code}, @status_timeout) do
      {:ok, status, answer} -> price_of(Reply.envelope(status, answer))
      {:error, _reason} -> nil
    end
  end

  defp price_of({:data, data}) do
    status =
      cond do
        data["gangguan"] == "Ya" -> "gangguan"
        data["kosong"] == "Ya" -> "kosong"
        true -> "normal"
      end

    %{price: Reply.money(data["harga"]), status: status}
  end

  defp price_of({:rc, code, _message}) when code in ["97", "89"],
    do: %{price: nil, status: "tidak_ditemukan"}

  defp price_of(_answer), do: nil

  # A signed request: `mmid` and the fields, `sign` over the ones SBI signs.
  defp call(credentials, action, fields, timeout) do
    mmid = credentials["member_id"]
    body = Map.put(fields, "mmid", mmid)

    sign =
      Sign.sign(
        mmid,
        fields["product_code"],
        fields["customer_id"],
        fields["ref_1"],
        credentials["pin"],
        credentials["password"]
      )

    client().post(action, body, [{"sign", sign}, {"content-type", "application/json"}], timeout)
  end

  @doc false
  def config, do: Application.get_env(:zahlungs, __MODULE__, [])

  defp client, do: Keyword.get(config(), :client, Zahlungs.Services.Provider.Sbi.Client)
end
