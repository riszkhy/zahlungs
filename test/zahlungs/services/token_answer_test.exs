defmodule Zahlungs.Services.TokenAnswerTest do
  use ExUnit.Case, async: true

  alias Zahlungs.Services.TokenAnswer

  @answer "1111-2222-3333-4444-5555/BUDI SANTOSO/R1M/900VA/16,9KWH"

  test "reads the token, the owner, the tariff and the kWh" do
    assert TokenAnswer.parse(@answer) == %{
             token: "11112222333344445555",
             name: "BUDI SANTOSO",
             tariff: "R1M/900VA",
             kwh: "16,9 kWh"
           }
  end

  test "a kWh written another way is kept as written" do
    answer = "1111-2222-3333-4444-5555/BUDI/R1/450/sekitar 7"
    assert TokenAnswer.parse(answer).kwh == "sekitar 7"
  end

  test "a blank part is none" do
    assert %{name: nil, kwh: nil, tariff: "R1/450"} =
             TokenAnswer.parse("1111-2222-3333-4444-5555/ /R1/450/ ")
  end

  test "anything else is not a token answer, so it is shown whole" do
    for other <- [
          nil,
          "",
          "R240814.1900.210036",
          "11112222333344445555",
          "5821 0344 9917 2268 4410",
          # Too few or too many parts.
          "1111-2222-3333-4444-5555/BUDI/R1/450",
          "1111-2222-3333-4444-5555/BUDI/R1/450/7KWH/LAGI",
          # Not 20 digits.
          "1111-2222-3333-4444/BUDI/R1/450/7KWH",
          "1111-2222-3333-4444-555A/BUDI/R1/450/7KWH"
        ] do
      assert TokenAnswer.parse(other) == nil
    end
  end
end
