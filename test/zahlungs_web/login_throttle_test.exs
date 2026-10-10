defmodule ZahlungsWeb.LoginThrottleTest do
  use ExUnit.Case, async: true

  alias ZahlungsWeb.LoginThrottle

  defp email, do: "throttle#{System.unique_integer([:positive])}@example.com"

  test "allows attempts until the limit of failures is reached, then asks to wait" do
    email = email()
    ip = "198.51.100.1"

    for _ <- 1..4 do
      assert LoginThrottle.check(email, ip) == :ok
      LoginThrottle.record_failure(email, ip)
    end

    assert LoginThrottle.check(email, ip) == :ok
    LoginThrottle.record_failure(email, ip)

    assert {:error, seconds} = LoginThrottle.check(email, ip)
    assert seconds > 0 and seconds <= 900
  end

  test "counts per email and address, ignoring case and surrounding spaces" do
    email = email()
    for _ <- 1..5, do: LoginThrottle.record_failure(email, "198.51.100.2")

    assert {:error, _} = LoginThrottle.check(" " <> String.upcase(email) <> " ", "198.51.100.2")
    assert LoginThrottle.check(email, "198.51.100.3") == :ok
    assert LoginThrottle.check(email(), "198.51.100.2") == :ok
  end

  test "a successful login clears the count" do
    email = email()
    for _ <- 1..5, do: LoginThrottle.record_failure(email, "198.51.100.4")

    LoginThrottle.reset(email, "198.51.100.4")

    assert LoginThrottle.check(email, "198.51.100.4") == :ok
  end
end
