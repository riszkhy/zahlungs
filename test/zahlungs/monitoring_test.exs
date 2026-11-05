defmodule Zahlungs.MonitoringTest do
  use Zahlungs.DataCase, async: true

  alias Zahlungs.Monitoring
  alias Zahlungs.Organizations.Organization

  @now ~N[2026-11-05 12:00:00]
  @today ~D[2026-11-05]

  defp at_ago(seconds), do: NaiveDateTime.add(@now, -seconds)

  defp org(attrs), do: struct(%Organization{status: "active"}, attrs)

  describe "activity/2" do
    test "the edge of a band belongs to the more active one" do
      assert Monitoring.activity(at_ago(7 * 86_400), @now) == :active
      assert Monitoring.activity(at_ago(7 * 86_400 + 1), @now) == :quiet
      assert Monitoring.activity(at_ago(30 * 86_400), @now) == :quiet
      assert Monitoring.activity(at_ago(30 * 86_400 + 1), @now) == :asleep
    end

    test "no transaction at all is never" do
      assert Monitoring.activity(nil, @now) == :never
    end
  end

  describe "billing/2" do
    test "an active organization by its paid-until date" do
      assert Monitoring.billing(org(paid_until: nil), @today) == :unrecorded
      assert Monitoring.billing(org(paid_until: ~D[2026-11-04]), @today) == :overdue
      assert Monitoring.billing(org(paid_until: ~D[2026-11-05]), @today) == :due_soon
      assert Monitoring.billing(org(paid_until: ~D[2026-11-12]), @today) == :due_soon
      assert Monitoring.billing(org(paid_until: ~D[2026-11-13]), @today) == :ok
    end

    test "an organization that isn't active has no billing state" do
      for status <- ~w(pending suspended rejected) do
        assert Monitoring.billing(org(status: status, paid_until: ~D[2026-01-01]), @today) == nil
      end
    end
  end

  test "the wait before a service counts as stuck has one source" do
    assert Zahlungs.Services.settle_by_hand_after() == 600
  end
end
