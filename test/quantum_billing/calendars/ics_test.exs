defmodule QuantumBilling.Calendars.ICSTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Calendars.ICS

  @now ~U[2026-10-30 09:00:00Z]

  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        key: "task:1",
        title: "Renew licence",
        description: nil,
        date: ~D[2026-11-20],
        alarm_days: 3
      },
      overrides
    )
  end

  defp unfold(text), do: String.replace(text, "\r\n ", "")

  test "an all-day event ends the next day" do
    text = ICS.single_event("uid-1", item(), @now)

    assert text =~ "DTSTART;VALUE=DATE:20261120\r\n"
    assert text =~ "DTEND;VALUE=DATE:20261121\r\n"
    assert text =~ "DTSTAMP:20261030T090000Z\r\n"
    assert text =~ "TRIGGER:-P3D\r\n"
    assert String.starts_with?(text, "BEGIN:VCALENDAR\r\n")
    assert String.ends_with?(text, "END:VCALENDAR\r\n")
  end

  test "an event with no alarm has no VALARM" do
    refute ICS.single_event("uid-1", item(%{alarm_days: nil}), @now) =~ "VALARM"
  end

  test "values are escaped" do
    assert ICS.escape("a,b;c\\d") == "a\\,b\\;c\\\\d"
    assert ICS.escape("one\r\ntwo\nthree") == "one\\ntwo\\nthree"
  end

  test "a line break in a title cannot add a property" do
    title = "Pay\r\nATTENDEE:mailto:someone@example.com\r\nEND:VEVENT"
    lines = "uid-1" |> ICS.single_event(item(%{title: title}), @now) |> String.split("\r\n")

    refute Enum.any?(lines, &String.starts_with?(&1, "ATTENDEE"))
    assert Enum.count(lines, &(&1 == "END:VEVENT")) == 1
  end

  test "control characters are stripped" do
    assert ICS.escape("a\0b\x07c\x7Fd") == "abcd"
  end

  test "long lines fold at 75 octets without splitting a character" do
    title = String.duplicate("वार्षिक रिटर्न ", 30)
    text = ICS.single_event("uid-1", item(%{title: title}), @now)

    for line <- String.split(text, "\r\n") do
      assert byte_size(line) <= 75
      assert String.valid?(line)
    end

    assert unfold(text) =~ "SUMMARY:" <> String.trim_trailing(title) <> " "
  end

  test "a calendar names itself and holds every event" do
    events = [{"uid-1", item()}, {"uid-2", item(%{key: "task:2", title: "Second"})}]
    text = ICS.calendar("Acme, Pune", events, @now)

    assert text =~ "X-WR-CALNAME:Acme\\, Pune\r\n"
    assert text =~ "UID:uid-1\r\n"
    assert text =~ "UID:uid-2\r\n"
  end
end
