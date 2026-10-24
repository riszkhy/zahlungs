defmodule Zahlungs.Services.ProviderFakeTest do
  @moduledoc """
  The fake PPOB provider used in development and tests: what it answers is
  decided by the last digit of the customer's number.
  """
  use ExUnit.Case, async: true

  alias Zahlungs.Services.Provider
  alias Zahlungs.Services.Provider.Fake

  @creds %{"secret" => "rahasia-uji"}

  defp pay(ref_id, customer_ref, product_code \\ "TSEL10"),
    do:
      Fake.pay(@creds, %{ref_id: ref_id, customer_ref: customer_ref, product_code: product_code})

  defp status(ref_id, customer_ref, product_code \\ "TSEL10"),
    do:
      Fake.status(@creds, %{
        ref_id: ref_id,
        customer_ref: customer_ref,
        product_code: product_code
      })

  defp inquiry(customer_ref),
    do: Fake.inquiry(@creds, %{product_code: "PLNPASCA", customer_ref: customer_ref})

  describe "the registry" do
    test "knows the registered adapters and nothing else" do
      assert Provider.adapter("fake") == {:ok, Fake}
      assert Provider.adapter("nope") == :error
      assert Provider.adapter(nil) == :error
      # Options follow the registry; "broken" (test only) has no label to offer.
      assert Provider.options() == [
               {"Smart Biller Indonesia (SBI)", "sbi"},
               {"Penyedia tiruan (uji coba)", "fake"}
             ]

      assert Fake.credential_fields() == [{"secret", "Secret callback"}]
    end
  end

  describe "inquiry/2" do
    test "one sheet or three, by the second-to-last digit" do
      assert {:ok, one} = inquiry("530011223341")
      assert {one.sheets, one.customer_name, one.period} == {1, "PELANGGAN 3341", "OKT 2026"}
      assert Decimal.equal?(one.bill_amount, Decimal.new(245_000))
      assert one.inquiry_ref == "INQ-530011223341"

      assert {:ok, three} = inquiry("530011223331")
      assert {three.sheets, three.period} == {3, "AGU–OKT 2026"}
      assert Decimal.equal?(three.bill_amount, Decimal.new(735_000))
    end

    test "refuses by the last digit" do
      assert inquiry("530011223346") == {:error, :not_found}
      assert inquiry("530011223345") == {:error, :already_paid}
      assert inquiry("530011223347") == {:error, :unavailable}
    end
  end

  describe "pay/2 and status/2" do
    test "succeed with a serial number, or a 20-digit token for PLN" do
      assert pay("R1", "081234567891") ==
               {:ok, %{status: :success, token_sn: "SNR1", provider_ref: "FAKE-R1"}}

      assert {:ok, %{status: :success, token_sn: token}} = pay("R2", "12345678901", "PLN20")
      assert token =~ ~r/^\d{20}$/
    end

    test "answer by the last digit" do
      assert {:ok, %{status: :failed, message: "Nomor tidak aktif"}} = pay("R", "081234567890")
      assert {:ok, %{status: :pending, provider_ref: "FAKE-R"}} = pay("R", "081234567899")
      assert {:ok, %{status: :pending}} = pay("R", "081234567898")
      assert pay("R", "081234567897") == {:error, :timeout}
      assert pay("R", "081234567894") == {:error, :timeout}
      assert {:ok, %{status: :success}} = pay("R", "081234567896")

      assert {:ok, %{status: :success}} = status("R", "081234567899")
      assert {:ok, %{status: :failed}} = status("R", "081234567898")
      assert {:ok, %{status: :success}} = status("R", "081234567897")
      assert status("R", "081234567894") == {:error, :not_found}
      assert {:ok, %{status: :failed}} = status("R", "081234567890")
    end

    test "tell the calling process about every call" do
      pay("R7", "081234567891")
      status("R7", "081234567891")

      assert_received {:fake_provider, :pay, "R7"}
      assert_received {:fake_provider, :status, "R7"}
    end
  end

  describe "verify_callback/3" do
    test "accepts a callback signed with the account's secret" do
      params = %{
        "ref_id" => "R9",
        "status" => "success",
        "token_sn" => "SN9",
        "provider_ref" => "P9"
      }

      headers = %{"x-fake-signature" => Fake.sign("rahasia-uji", "R9", "success")}

      assert Fake.verify_callback(@creds, params, headers) ==
               {:ok, "R9", %{status: :success, token_sn: "SN9", provider_ref: "P9"}}

      failed = %{"ref_id" => "R9", "status" => "failed", "message" => "Gagal"}
      failed_headers = %{"x-fake-signature" => Fake.sign("rahasia-uji", "R9", "failed")}

      assert Fake.verify_callback(@creds, failed, failed_headers) ==
               {:ok, "R9", %{status: :failed, message: "Gagal"}}
    end

    test "refuses a wrong or missing signature" do
      params = %{"ref_id" => "R9", "status" => "success"}
      wrong = %{"x-fake-signature" => Fake.sign("lain", "R9", "success")}

      assert Fake.verify_callback(@creds, params, wrong) == {:error, :invalid_signature}
      assert Fake.verify_callback(@creds, params, %{}) == {:error, :invalid_signature}
    end
  end

  describe "ping/1 and balance/1" do
    test "answer for any account" do
      assert Fake.ping(@creds) == :ok
      assert Fake.balance(@creds) == {:ok, Decimal.new("1000000")}
    end
  end
end
