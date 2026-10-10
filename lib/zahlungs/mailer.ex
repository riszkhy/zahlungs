defmodule Zahlungs.Mailer do
  use Swoosh.Mailer, otp_app: :zahlungs

  @doc """
  Whether an email sent now can actually reach its recipient.

  Swoosh's `Local` adapter only keeps messages in memory. That is useful in
  development (read them at `/dev/mailbox`) but in production it means nothing
  is ever delivered, so flows that depend on an emailed link must not be
  offered there until a real adapter is configured (see docs/DEPLOYMENT.md).
  """
  def delivers?(
        env \\ Application.get_env(:zahlungs, :env),
        config \\ Application.get_env(:zahlungs, __MODULE__, [])
      ) do
    env != :prod or config[:adapter] != Swoosh.Adapters.Local
  end
end
