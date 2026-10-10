defmodule QuantumBilling.Accounts.UserNotifier do
  import Swoosh.Email

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Mail

  # Account mail goes out over the same relay as everything else — the
  # organisation's own SMTP server when one is configured — and from the same
  # sender address. A confirmation link arriving from a stranger's domain is
  # how a sign-in mail ends up in a spam folder.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mail.sender())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mail.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Invites someone to create an account on this installation.

  Says plainly what the account is for and that the link expires, because an
  invitation to a billing system that explains nothing looks exactly like
  phishing.
  """
  def deliver_invitation(invitation, url) do
    days = QuantumBilling.Accounts.Invitation.validity_days()

    deliver(invitation.email, "You have been invited to QuantumBilling", """

    ==============================

    Hi #{invitation.email},

    You have been invited to create an account on QuantumBilling, the GST
    billing and compliance system used by this business.

    Create your account here:

    #{url}

    This link works once and expires in #{days} days. It only works for this
    email address.

    If you were not expecting this, ignore it — no account is created until
    someone uses the link.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to confirm a newly created account.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset a forgotten password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    This link expires in 4 hours and can only be used once.

    If you didn't request a new password, please ignore this — your current
    password will keep working.

    ==============================
    """)
  end
end
