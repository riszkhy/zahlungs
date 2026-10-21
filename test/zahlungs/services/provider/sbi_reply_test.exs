defmodule Zahlungs.Services.Provider.SbiReplyTest do
  @moduledoc """
  Signing requests to Smart Biller Indonesia and reading its answers, from the
  examples in its technical document and Postman collection.
  """
  use ExUnit.Case, async: true

  alias Zahlungs.Services.Provider.Sbi.{Reply, Sign}

  defp d(value), do: Decimal.new(value)

  @topup_success %{
    "ref_1" => "13896521371941",
    "ref_2" => "2406070150146356",
    "product_code" => "T1",
    "customer_id" => "089652137194",
    "status" => 1,
    "status_label" => "success",
    "price" => "2000",
    "total_payment" => "2000",
    "msg" => "TRX T1.089652137194 SUKSES, HRG:2000 SN:7867867686876 REFID:13896521371941."
  }

  @inquiry_pln %{
    "ref_1" => "717861687671211",
    "ref_2" => "2406070110697924",
    "product_code" => "PLN",
    "customer_id" => "546302215889",
    "status" => 1,
    "price" => "300000",
    "admin" => "2750",
    "total_price" => "302750",
    "total_payment" => "302750",
    "msg" =>
      "INQ PLN.546302215889 SUKSES, DATA:Anto /R1 /Daya=1300 / HRG:302750 REFID:717861687671211.",
    "detail" => %{"admin" => 2750, "data_1" => "Anto ", "data_2" => "R1 /Daya=1300 /"}
  }

  describe "Sign.sign/6" do
    test "is the url-safe base64 of the SHA-1, without padding" do
      assert Sign.sign("MM123", "T1", "089652137194", "Z1261021153000A1B2C3", "1234", "rahasia") ==
               "8GaWqL-wPFtQPzwk3naUFgFV52M"
    end

    test "missing fields are empty" do
      assert Sign.sign("MM123", nil, nil, nil, "1234", "rahasia") ==
               "I7rFuxRBQUEMuHpUZPouA2dU1VY"
    end
  end

  describe "transaction/1" do
    test "a success keeps the SN, the actual cost and SBI's ref" do
      assert {:ok, result} = Reply.transaction(@topup_success)

      assert %{status: :success, token_sn: "7867867686876", provider_ref: "2406070150146356"} =
               result

      assert Decimal.equal?(result.actual_cost, d("2000"))
      assert result.payload == Jason.encode!(@topup_success)
    end

    test "the cost falls back to HRG in the message" do
      answer = Map.delete(@topup_success, "total_payment")
      assert {:ok, %{actual_cost: cost}} = Reply.transaction(answer)
      assert Decimal.equal?(cost, d("2000"))
    end

    test "status 2 is pending" do
      assert {:ok, %{status: :pending, provider_ref: "2406070150146356"}} =
               Reply.transaction(%{@topup_success | "status" => 2, "msg" => "TRX T1 PENDING"})
    end

    test "status 11 is a failure, with SBI's reason" do
      answer = %{
        @topup_success
        | "status" => 11,
          "msg" =>
            "GAGAL, RC:14. TRX TP15.082236929165 KET:Nomor tujuan salah. SALDO:641093543 REFID:703674211."
      }

      assert {:ok, %{status: :failed, message: "Nomor tujuan salah."}} = Reply.transaction(answer)
    end

    test "a failure without a reason keeps the message" do
      answer = %{@topup_success | "status" => 11, "msg" => "TRX PLN20.08786868768 GAGAL. KET:"}

      assert {:ok, %{status: :failed, message: "TRX PLN20.08786868768 GAGAL. KET:"}} =
               Reply.transaction(answer)
    end

    test "a duplicate ref or a biller timeout is pending, never failed" do
      for rc <- ["94", "08"] do
        answer = %{@topup_success | "status" => 11, "msg" => "GAGAL, RC:#{rc}. KET:apa saja"}
        assert {:ok, %{status: :pending}} = Reply.transaction(answer)
      end
    end

    test "a bad mitra, IP, signature or ID asks the admin to check SBI's settings" do
      for rc <- ["91", "92", "93", "95"] do
        answer = %{@topup_success | "status" => 11, "msg" => "GAGAL, RC:#{rc}. KET:x"}

        assert {:ok, %{status: :failed, message: "Periksa kredensial / IP server di SBI"}} =
                 Reply.transaction(answer)
      end
    end

    test "RC:31 is a refund" do
      answer = %{@topup_success | "status" => 11, "msg" => "GAGAL, RC:31. KET:Refund transaksi"}
      assert {:ok, %{status: :refunded, message: "Refund transaksi"}} = Reply.transaction(answer)
    end

    test "an unknown status is pending" do
      assert {:ok, %{status: :pending}} = Reply.transaction(%{@topup_success | "status" => 7})
    end

    test "a success without an SN has none" do
      no_sn = %{@topup_success | "msg" => "TRX T1.089652137194 SUKSES, HRG:2000 REFID:1."}
      assert {:ok, %{status: :success, token_sn: nil}} = Reply.transaction(no_sn)

      empty = %{@topup_success | "msg" => "TRX T1 SUKSES SN: REFID:x"}
      assert {:ok, %{status: :success, token_sn: nil}} = Reply.transaction(empty)
    end

    test "the inquiry's own row (same ref_1) is not a payment" do
      # A bill is paid with its inquiry's ref, so a status check during a slow
      # payment may return the inquiry: never a success.
      assert {:ok, %{status: :pending}} = Reply.transaction(@inquiry_pln)

      pdf = %{
        @inquiry_pln
        | "msg" => "SUKSES CEK TAGIHAN PLNPASC IDPEL:524030445147 @DATA: Nama:SUTARTO"
      }

      assert {:ok, %{status: :pending}} = Reply.transaction(pdf)
    end

    test "the SN stops before the shop's balance" do
      answer = %{
        @topup_success
        | "msg" =>
            "TRX T25.0895352090205 SUKSES, HRG:24493 SN: R240814.1900.210036. SALDO:640555995 REFID:703674299."
      }

      assert {:ok, %{token_sn: "R240814.1900.210036"}} = Reply.transaction(answer)
    end

    test "status as a string is read too" do
      assert {:ok, %{status: :success}} = Reply.transaction(%{@topup_success | "status" => "1"})
    end
  end

  describe "envelope/2" do
    test "the data object" do
      body = %{"status" => "success", "code" => 200, "data" => @topup_success}
      assert Reply.envelope(200, body) == {:data, @topup_success}
    end

    test "an RC in the message" do
      assert {:rc, "93", _} =
               Reply.envelope(200, %{
                 "status" => "failed",
                 "message" => "GAGAL, RC:93 Invalid signature"
               })

      assert {:rc, "94", _} = Reply.envelope(400, "GAGAL, RC:94. Duplicate Reff ID")
    end

    test "anything else is unknown" do
      assert Reply.envelope(200, "<html>oops</html>") == :unknown
      assert Reply.envelope(500, %{"data" => @topup_success}) == :unknown
      assert Reply.envelope(200, %{"status" => "failed"}) == :unknown
    end
  end

  describe "rc/2" do
    test "maps codes like a transaction's message" do
      assert %{status: :pending} = Reply.rc("94", "Duplicate Reff ID")
      assert %{status: :pending} = Reply.rc("08", "Timeout")
      assert %{status: :pending} = Reply.rc("777", "baru")

      assert %{status: :failed, message: "Saldo tidak cukup"} =
               Reply.rc("96", "Saldo tidak cukup")

      assert %{status: :failed, message: "Periksa kredensial / IP server di SBI"} =
               Reply.rc("92", "x")

      assert %{status: :refunded} = Reply.rc("31", "Refund")
    end
  end

  describe "inquiry/2" do
    test "a PLN bill from the Postman example" do
      assert {:ok, answer} = Reply.inquiry({:data, @inquiry_pln}, :bill)
      assert answer.customer_name == "Anto"
      assert {answer.sheets, answer.period, answer.inquiry_ref} == {1, nil, "2406070110697924"}
      assert Decimal.equal?(answer.bill_amount, d("300000"))
      assert Decimal.equal?(answer.provider_admin, d("2750"))
      assert Decimal.equal?(answer.provider_total, d("302750"))
      assert answer.details =~ "Daya=1300"
    end

    test "months and period from the message, as in the PDF" do
      answer = %{
        @inquiry_pln
        | "msg" =>
            "SUKSES CEK TAGIHAN PLNPASC IDPEL:524030445147 @DATA: Nama:SUTARTO/Tarif daya:R1 450/Ref:/Jml bulan:2/Blth:JUL 24, AGU 24/Tagihan:Rp59962/Admin:Rp6000/Total:Rp65962. SALDO:83695"
      }

      answer = Map.delete(answer, "detail")

      assert {:ok, %{sheets: 2, period: "JUL 24, AGU 24", customer_name: "SUTARTO"}} =
               Reply.inquiry({:data, answer}, :bill)
    end

    test "a meter's owner has no amount" do
      assert {:ok, answer} = Reply.inquiry({:data, @inquiry_pln}, :customer)
      assert answer.customer_name == "Anto"
      assert is_nil(answer.bill_amount)
      assert is_nil(answer.provider_total)
    end

    test "SBI's refusals" do
      failed = fn rc, ket ->
        {:data, %{@inquiry_pln | "status" => 11, "msg" => "GAGAL, RC:#{rc}. KET:#{ket}"}}
      end

      assert Reply.inquiry(failed.("14", "Nomor tujuan salah"), :bill) == {:error, :not_found}
      assert Reply.inquiry(failed.("15", "x"), :bill) == {:error, :not_found}
      assert Reply.inquiry(failed.("05", "x"), :bill) == {:error, :not_found}
      assert Reply.inquiry(failed.("88", "x"), :bill) == {:error, :already_paid}

      assert Reply.inquiry(failed.("83", "x"), :bill) ==
               {:error, {:rejected, "Tagihan belum tersedia."}}

      assert Reply.inquiry(failed.("16", "x"), :bill) ==
               {:error, {:rejected, "Nomor meter diblokir."}}

      assert Reply.inquiry(failed.("84", "x"), :bill) == {:error, :unavailable}
      assert Reply.inquiry(failed.("98", "x"), :bill) == {:error, :unavailable}

      assert Reply.inquiry(failed.("30", "Gagal dari biller"), :bill) ==
               {:error, {:rejected, "Gagal dari biller"}}

      assert Reply.inquiry({:rc, "84", "Cut off"}, :bill) == {:error, :unavailable}
      assert Reply.inquiry(:unknown, :bill) == {:error, :unavailable}
    end
  end

  describe "money/1" do
    test "reads strings, integers and floats" do
      assert Decimal.equal?(Reply.money("302750"), d("302750"))
      assert Decimal.equal?(Reply.money(302_750), d("302750"))
      assert Decimal.equal?(Reply.money(-283_695), d("-283695"))
      assert Decimal.equal?(Reply.money(1500.0), d("1500"))
    end

    test "anything else is nothing" do
      assert is_nil(Reply.money(""))
      assert is_nil(Reply.money(nil))
      assert is_nil(Reply.money("abc"))
    end
  end
end
