defmodule QuantumBillingWeb.PublicDocumentRateLimitTest do
  use QuantumBillingWeb.ConnCase, async: true

  alias QuantumBilling.RateLimiter
  alias QuantumBillingWeb.ClientIP
  alias QuantumBillingWeb.Plugs.PublicDocumentRateLimit

  @client_ip {192, 0, 2, 68}
  @other_ip {192, 0, 2, 69}
  @document_pdf "/p/missing/document/pdf"
  @calendar_feed "/calendar/missing/feed.ics"

  setup do
    for bucket <- [:public_document, :calendar_feed], ip <- [@client_ip, @other_ip] do
      RateLimiter.reset({bucket, ClientIP.to_string_ip(ip)})
    end

    :ok
  end

  test "all public document routes share a bucket, separate from calendar and legal pages" do
    # The last request the limit allows still reaches the router.
    fill_bucket(:public_document, PublicDocumentRateLimit.limit() - 1)
    assert request(@document_pdf).status == 404

    for path <- [
          ~p"/p/missing/document",
          @document_pdf,
          ~p"/pay/document",
          ~p"/pay/document/pdf",
          ~p"/q/missing/document",
          ~p"/q/missing/document/pdf"
        ] do
      conn = request(path)
      assert response(conn, 429) == "Too many requests"
      assert response_content_type(conn, :text)
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..60
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    assert request(@calendar_feed).status == 404
    assert request(@document_pdf, @other_ip).status == 404
    assert request(~p"/terms").status == 200
    assert request(~p"/privacy").status == 200
  end

  test "a full calendar bucket leaves the same address's public document allowance available" do
    fill_bucket(:calendar_feed, 60)

    assert request(@calendar_feed).status == 429
    assert request(@document_pdf).status == 404
  end

  defp fill_bucket(bucket, count) do
    key = {bucket, ClientIP.to_string_ip(@client_ip)}
    for _ <- 1..count, do: RateLimiter.hit(key, count, 60)
  end

  defp request(path, ip \\ @client_ip), do: get(%{build_conn() | remote_ip: ip}, path)
end
