defmodule Zahlungs.Services.Provider.SbiTest do
  @moduledoc """
  The Smart Biller Indonesia adapter against `Sbi.StubClient`: what it sends
  (signed JSON) and how it reads what comes back. No request reaches SBI.
  """
  use ExUnit.Case, async: true

  alias Zahlungs.Services.Provider
  alias Zahlungs.Services.Provider.Sbi
  alias Zahlungs.Services.Provider.Sbi.{Sign, StubClient}

  @credentials %{"member_id" => "MM123", "pin" => "1234", "password" => "rahasia"}

  @topup %{
    "ref_1" => "Z1261021153000A1B2C3",
    "ref_2" => "2406070150146356",
    "status" => 1,
    "total_payment" => "2000",
    "msg" => "TRX T1.089652137194 SUKSES, HRG:2000 SN:7867867686876 REFID:Z1261021153000A1B2C3."
  }

  defp ok(data), do: {:ok, 200, %{"status" => "success", "code" => 200, "data" => data}}
  defp error(message), do: {:ok, 200, %{"status" => "failed", "message" => message}}

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        ref_id: "Z1261021153000A1B2C3",
        product_code: "T1",
        customer_ref: "089652137194",
        inquiry_ref: nil
      },
      extra
    )
  end

  test "asks for a member ID, a PIN and a password" do
    assert Sbi.credential_fields() == [
             {"member_id", "Member ID"},
             {"pin", "PIN"},
             {"password", "Password"}
           ]
  end

  test "is offered as a provider" do
    assert {"Smart Biller Indonesia (SBI)", "sbi"} in Provider.options()
    assert Provider.adapter("sbi") == {:ok, Sbi}
  end

  describe "pay/2" do
    test "a topup is signed JSON, and its success keeps the SN" do
      StubClient.expect("topup", ok(@topup))

      assert {:ok, %{status: :success, token_sn: "7867867686876"}} =
               Sbi.pay(@credentials, request())

      assert [{"topup", body, headers}] = StubClient.requests()

      assert body == %{
               "mmid" => "MM123",
               "ref_1" => "Z1261021153000A1B2C3",
               "product_code" => "T1",
               "customer_id" => "089652137194"
             }

      sign = Sign.sign("MM123", "T1", "089652137194", "Z1261021153000A1B2C3", "1234", "rahasia")
      assert {"sign", sign} in headers
      refute Enum.any?(headers, fn {_name, value} -> value =~ "rahasia" end)
    end

    test "a bill is a payment with SBI's ref from the inquiry" do
      StubClient.expect("payment", ok(@topup))
      Sbi.pay(@credentials, request(%{product_code: "PLN", inquiry_ref: "2406070110697924"}))

      assert [{"payment", %{"ref_2" => "2406070110697924", "product_code" => "PLN"}, _}] =
               StubClient.requests()
    end

    test "no answer, a server error or a page that isn't JSON is a timeout (pending)" do
      StubClient.expect("topup", {:error, :timeout})
      StubClient.expect("topup", {:error, :network})
      StubClient.expect("topup", {:ok, 500, %{}})
      StubClient.expect("topup", {:ok, 200, "<html>bad gateway</html>"})

      for _ <- 1..4, do: assert(Sbi.pay(@credentials, request()) == {:error, :timeout})
    end

    test "a duplicate ref or a biller timeout is pending; a known refusal fails" do
      StubClient.expect("topup", error("GAGAL, RC:94. Duplicate Reff ID"))
      StubClient.expect("topup", error("GAGAL, RC:08. Timeout dari biller"))
      StubClient.expect("topup", error("GAGAL, RC:96. KET:Saldo tidak cukup"))
      StubClient.expect("topup", error("GAGAL, RC:91. Invalid mitra"))

      assert {:ok, %{status: :pending}} = Sbi.pay(@credentials, request())
      assert {:ok, %{status: :pending}} = Sbi.pay(@credentials, request())

      assert {:ok, %{status: :failed, message: "Saldo tidak cukup"}} =
               Sbi.pay(@credentials, request())

      assert {:ok, %{status: :failed, message: "Periksa kredensial / IP server di SBI"}} =
               Sbi.pay(@credentials, request())
    end
  end

  describe "status/2" do
    test "asks about the ref, signed with empty product and customer" do
      StubClient.expect("status", ok(%{@topup | "status" => 2}))
      assert {:ok, %{status: :pending}} = Sbi.status(@credentials, request())

      assert [{"status", %{"mmid" => "MM123", "ref_1" => "Z1261021153000A1B2C3"} = body, headers}] =
               StubClient.requests()

      refute Map.has_key?(body, "product_code")

      assert {"sign", Sign.sign("MM123", "", "", "Z1261021153000A1B2C3", "1234", "rahasia")} in headers
    end

    test "an error answer without data is not known yet, never a failure" do
      StubClient.expect("status", error("GAGAL, RC:95. Invalid ID"))
      assert Sbi.status(@credentials, request()) == {:error, :not_found}
    end
  end

  describe "inquiry/2" do
    test "a bill uses its product code; a meter's owner uses CPLNPRA" do
      answer = %{
        "ref_2" => "2406070110697924",
        "status" => 1,
        "price" => "300000",
        "admin" => "2750",
        "total_payment" => "302750",
        "msg" => "INQ PLN SUKSES",
        "detail" => %{"data_1" => "Anto ", "data_2" => "R1 /Daya=1300 /"}
      }

      StubClient.expect("inquiry", ok(answer))
      StubClient.expect("inquiry", ok(answer))

      bill = %{ref_id: "Q1", product_code: "PLN", customer_ref: "546302215889", kind: :bill}
      assert {:ok, %{customer_name: "Anto", sheets: 1}} = Sbi.inquiry(@credentials, bill)

      owner = %{bill | product_code: "PLN20", kind: :customer}
      assert {:ok, %{bill_amount: nil}} = Sbi.inquiry(@credentials, owner)

      assert [
               {"inquiry", %{"product_code" => "PLN", "ref_1" => "Q1"}, _},
               {"inquiry", %{"product_code" => "CPLNPRA"}, _}
             ] = StubClient.requests()
    end

    test "a meter's owner is checked with the product's own check code when it has one" do
      answer = %{
        "ref_2" => "S1",
        "status" => 1,
        "msg" => "INQ SUKSES",
        "detail" => %{"data_1" => "Anto"}
      }

      StubClient.expect("inquiry", ok(answer))
      StubClient.expect("inquiry", ok(answer))

      owner = %{ref_id: "Q1", product_code: "PLN20", customer_ref: "14123344441", kind: :customer}
      Sbi.inquiry(@credentials, Map.put(owner, :check_code, "CEKPLN"))
      Sbi.inquiry(@credentials, Map.put(owner, :check_code, ""))

      assert [
               {"inquiry", %{"product_code" => "CEKPLN"}, check_headers},
               {"inquiry", %{"product_code" => "CPLNPRA"}, _}
             ] = StubClient.requests()

      sign = Sign.sign("MM123", "CEKPLN", "14123344441", "Q1", "1234", "rahasia")
      assert {"sign", sign} in check_headers
    end

    test "no answer is unavailable" do
      StubClient.expect("inquiry", {:error, :timeout})
      inquiry = %{ref_id: "Q1", product_code: "PLN", customer_ref: "546302215889", kind: :bill}
      assert Sbi.inquiry(@credentials, inquiry) == {:error, :unavailable}
    end
  end

  describe "balance and connection" do
    test "the balance may be negative" do
      StubClient.expect("balance", ok(%{"saldo" => -283_695}))
      assert {:ok, balance} = Sbi.balance(@credentials)
      assert Decimal.equal?(balance, Decimal.new("-283695"))
    end

    test "the connection test is a balance check" do
      StubClient.expect("balance", ok(%{"saldo" => 1000}))
      StubClient.expect("balance", error("GAGAL, RC:93. Invalid signature"))

      assert Sbi.ping(@credentials) == :ok
      assert {:error, message} = Sbi.ping(@credentials)
      assert message =~ "RC:93"
    end
  end

  describe "prices/2" do
    test "the member's price and whether each code can be sold" do
      StubClient.expect(
        "price",
        ok(%{"kode" => "T1", "harga" => "2000", "gangguan" => "Tidak", "kosong" => "Tidak"})
      )

      StubClient.expect(
        "price",
        ok(%{"kode" => "T2", "harga" => "3000", "gangguan" => "Ya", "kosong" => "Tidak"})
      )

      StubClient.expect("price", error("GAGAL, RC:97. Invalid product code"))

      # One request at a time here, so the queued answers match the codes in order.
      assert {:ok, prices} = Sbi.prices(@credentials, ["T1", "T2", "XX99"], max_concurrency: 1)

      assert %{status: "normal"} = prices["T1"]
      assert Decimal.equal?(prices["T1"].price, Decimal.new("2000"))
      assert %{status: "gangguan"} = prices["T2"]
      assert %{status: "tidak_ditemukan", price: nil} = prices["XX99"]
    end
  end

  test "a callback is found by ref_1" do
    assert Sbi.callback_ref(%{"ref_1" => "Z1"}) == {:ok, "Z1"}
    assert Sbi.callback_ref(%{"ref_1" => ""}) == :error
    assert Sbi.callback_ref(%{}) == :error
  end
end
