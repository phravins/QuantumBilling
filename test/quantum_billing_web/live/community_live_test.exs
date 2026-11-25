defmodule QuantumBillingWeb.CommunityLiveTest do
  @moduledoc "The Community page: contributor avatars from GitHub, stubbed here."
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp github(conn) do
    case conn.host do
      "api.github.com" ->
        Req.Test.json(conn, [
          %{
            "login" => "ada",
            "type" => "User",
            "contributions" => 12,
            "avatar_url" => "https://avatars.githubusercontent.com/u/1?v=4"
          },
          %{"login" => "grace", "type" => "User", "contributions" => 1, "avatar_url" => nil},
          %{"login" => "robot", "type" => "Bot", "contributions" => 40}
        ])

      "avatars.githubusercontent.com" ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png", nil)
        |> Plug.Conn.send_resp(200, @png)
    end
  end

  test "shows each contributor as an avatar circle linking to their profile", %{conn: conn} do
    Req.Test.stub(QuantumBilling.GitHub, &github/1)

    {:ok, view, _html} = live(conn, ~p"/community")
    assert has_element?(view, "#settings-back")
    assert has_element?(view, ~s(#settings-link-community[aria-current="page"]))

    render_async(view, 5_000)

    assert has_element?(
             view,
             ~s(#contributor-ada[href="https://github.com/ada"] img[src^="data:image/png;base64,"])
           )

    # No avatar: an initials circle instead.
    assert has_element?(view, "#contributor-grace")
    refute has_element?(view, "#contributor-grace img")
    # Bots are left out.
    refute has_element?(view, "#contributor-robot")
  end

  test "falls back to a link when GitHub cannot be reached", %{conn: conn} do
    Req.Test.stub(QuantumBilling.GitHub, &Plug.Conn.send_resp(&1, 503, ""))

    {:ok, view, _html} = live(conn, ~p"/community")
    render_async(view, 5_000)

    assert has_element?(view, "#contributors-unavailable")
    refute has_element?(view, "#contributors")
    assert has_element?(view, "#community-contribute")
  end
end
