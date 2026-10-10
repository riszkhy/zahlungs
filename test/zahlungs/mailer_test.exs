defmodule Zahlungs.MailerTest do
  use ExUnit.Case, async: true

  alias Zahlungs.Mailer

  describe "delivers?/2" do
    test "is false only in production with the in-memory Local adapter" do
      refute Mailer.delivers?(:prod, adapter: Swoosh.Adapters.Local)
      assert Mailer.delivers?(:prod, adapter: Swoosh.Adapters.SMTP)
    end

    test "is true in development and test, where messages can be inspected" do
      assert Mailer.delivers?(:dev, adapter: Swoosh.Adapters.Local)
      assert Mailer.delivers?(:test, adapter: Swoosh.Adapters.Test)
      assert Mailer.delivers?()
    end
  end
end
