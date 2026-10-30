defmodule QuantumBilling.Calendars.ICS do
  @moduledoc """
  Writes iCalendar (RFC 5545) text: all-day events with an optional alarm.

  Titles and notes come from people, so every value is escaped and stripped of
  control characters. Without that, a line break in a task title could add
  properties of its own to the event.
  """

  # The longest a line may be, in octets, before it has to be folded.
  @line_limit 75

  @doc "A whole calendar, for a subscription feed."
  def calendar(name, events, %DateTime{} = now \\ DateTime.utc_now()) do
    lines =
      header() ++
        ["X-WR-CALNAME:" <> escape(name)] ++
        Enum.flat_map(events, fn {uid, item} -> event_lines(uid, item, now) end) ++
        ["END:VCALENDAR"]

    render(lines)
  end

  @doc "A calendar holding one event, which is what CalDAV stores per resource."
  def single_event(uid, item, %DateTime{} = now \\ DateTime.utc_now()) do
    render(header() ++ event_lines(uid, item, now) ++ ["END:VCALENDAR"])
  end

  defp header do
    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//QuantumBilling//Compliance Calendar//EN",
      "CALSCALE:GREGORIAN"
    ]
  end

  defp event_lines(uid, item, now) do
    [
      "BEGIN:VEVENT",
      "UID:" <> escape(uid),
      "DTSTAMP:" <> stamp(now),
      "DTSTART;VALUE=DATE:" <> date(item.date),
      "DTEND;VALUE=DATE:" <> date(Date.add(item.date, 1)),
      "SUMMARY:" <> escape(item.title),
      "TRANSP:TRANSPARENT"
    ] ++
      description_lines(item.description) ++
      alarm_lines(item) ++
      ["END:VEVENT"]
  end

  defp description_lines(value) when value in [nil, ""], do: []
  defp description_lines(value), do: ["DESCRIPTION:" <> escape(value)]

  defp alarm_lines(%{alarm_days: days, title: title}) when is_integer(days) and days >= 0 do
    [
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      "DESCRIPTION:" <> escape(title),
      "TRIGGER:-P#{days}D",
      "END:VALARM"
    ]
  end

  defp alarm_lines(_item), do: []

  defp date(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")
  defp stamp(%DateTime{} = now), do: Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

  @doc "Escapes a text value, so it cannot break out of its property."
  def escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r\n|\r|\n/, "\\n")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
  end

  defp render(lines), do: Enum.map_join(lines, &(fold(&1) <> "\r\n"))

  @doc """
  Folds a line at 75 octets, on a character boundary. A continuation line starts
  with a space, and the space counts.
  """
  def fold(line) when byte_size(line) <= @line_limit, do: line

  def fold(line) do
    line
    |> String.codepoints()
    |> Enum.reduce({[], 0}, fn codepoint, {parts, size} ->
      width = byte_size(codepoint)

      if size + width > @line_limit do
        {[codepoint, "\r\n " | parts], width + 1}
      else
        {[codepoint | parts], size + width}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
