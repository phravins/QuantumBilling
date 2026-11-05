defmodule QuantumBilling.Compliance.ReminderEmail do
  @moduledoc """
  The email a task or reminder sends its author when "Also email me" is on.

  It goes through the same queue and delivery ledger as every other message —
  `QuantumBilling.Workers.EmailWorker` — so a relay that is down retries rather
  than losing the reminder, and Settings › SMTP shows whether it arrived.

  Only ever to the task's author: the address is read from their account when
  the email is queued, never from a form.
  """
  import Swoosh.Email

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.Mail
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.EmailWorker

  @doc """
  Queues the reminder email for `task`'s author.

  Returns `{:ok, delivery}`, or `{:error, :no_recipient}` for a task whose
  author has gone.
  """
  def deliver_async(%Task{} = task, due_phrase) do
    with %User{email: email} when is_binary(email) <- author(task),
         subject = subject_line(task, due_phrase),
         {:ok, delivery} <-
           Mail.record_queued(%{to_email: email, kind: "reminder", subject: subject}),
         {:ok, _job} <-
           %{
             "delivery_id" => delivery.id,
             "compliance_task_id" => task.id,
             "due_phrase" => due_phrase
           }
           |> EmailWorker.new()
           |> Oban.insert() do
      {:ok, delivery}
    else
      nil -> {:error, :no_recipient}
      %User{} -> {:error, :no_recipient}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The finished email for `task`, addressed to `recipient`."
  def build_email(recipient, %Task{} = task, due_phrase) do
    organization = Settings.get_organization()
    {from_name, from_email} = Mail.sender(organization)

    new()
    |> to(recipient)
    |> from({from_name, from_email})
    |> subject(subject_line(task, due_phrase))
    |> text_body(body(task, due_phrase))
  end

  defp author(%Task{created_by_id: nil}), do: nil
  defp author(%Task{created_by_id: id}), do: Repo.get(User, id)

  defp subject_line(task, due_phrase), do: "Reminder: #{task.title} #{due_phrase}"

  defp body(task, due_phrase) do
    """
    #{task.title} #{due_phrase}.

    Due: #{Calendar.strftime(task.due_date, "%A, %d %B %Y")}#{time_line(task)}
    #{notes(task)}
    Open the Compliance page to mark it done.

    You are getting this because you asked to be emailed about this
    #{if task.kind == "reminder", do: "reminder", else: "task"} in QuantumBilling.
    """
  end

  defp time_line(%Task{remind_at: %Time{} = time}),
    do: "\nReminder time: #{Calendar.strftime(time, "%I:%M %p")}"

  defp time_line(_task), do: ""

  defp notes(%Task{notes: notes}) when is_binary(notes) and notes != "",
    do: "\nNotes:\n#{notes}\n"

  defp notes(_task), do: ""
end
