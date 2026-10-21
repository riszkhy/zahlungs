defmodule Zahlungs.Services.Provider.Sbi.StubClient do
  @moduledoc """
  Stands in for `Zahlungs.Services.Provider.Sbi.Client` in tests: no request
  ever reaches Smart Biller Indonesia. A test queues answers per action with
  `expect/2`; requests are answered in order and recorded for `requests/0`.

  Answers belong to the test process and are found from the calling process
  or its `$callers` (a `Task` started by the code under test), so async tests
  don't see each other's. `start/0` (from `test_helper.exs`) creates the table.
  """

  @table :sbi_stub_client

  @doc "Creates the shared table; called once from test_helper.exs."
  def start do
    owner =
      spawn(fn ->
        :ets.new(@table, [:named_table, :public, :set])

        receive do
          :stop -> :ok
        end
      end)

    wait_for_table()
    owner
  end

  defp wait_for_table do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(5)
      wait_for_table()
    end
  end

  @doc "Queues `answer` for the next request with `action` (`\"pricelist\"` for `get_json/2`)."
  def expect(action, answer) do
    key = {self(), action}
    queue = lookup(key)
    :ets.insert(@table, {key, queue ++ [answer]})
    :ok
  end

  @doc "The requests the test sent so far, oldest first: `{action, body, headers}`."
  def requests do
    lookup({self(), :requests})
  end

  def post(action, body, headers, _timeout) do
    answer(action, {action, body, headers})
  end

  def get_json(url, _timeout) do
    answer("pricelist", {"pricelist", url, []})
  end

  defp answer(action, request) do
    owner =
      Enum.find([self() | Process.get(:"$callers", [])], fn pid -> lookup({pid, action}) != [] end) ||
        raise "StubClient: no answer queued for #{inspect(action)}"

    [answer | rest] = lookup({owner, action})
    :ets.insert(@table, {{owner, action}, rest})
    :ets.insert(@table, {{owner, :requests}, lookup({owner, :requests}) ++ [request]})
    answer
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> []
    end
  end
end
