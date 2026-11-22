defmodule EvoDash.ChatGPTLogin.PasteTest do
  # async: true — the parser is a pure function over its argument and touches no
  # process, table or app env.
  use ExUnit.Case, async: true

  alias EvoDash.ChatGPTLogin.Paste

  @url "http://127.0.0.1:1455/auth/callback"

  test "a full redirect URL becomes its code and state" do
    assert Paste.parse("#{@url}?code=abc&state=xyz") ==
             {:ok, %{"code" => "abc", "state" => "xyz"}}
  end

  test "a redirect URL on any host or scheme is accepted" do
    assert Paste.parse("https://example.com/elsewhere/cb?code=abc") == {:ok, %{"code" => "abc"}}

    assert Paste.parse("http://localhost:9/cb?code=abc&state=s") ==
             {:ok, %{"code" => "abc", "state" => "s"}}
  end

  test "a ?-prefixed query string becomes its parameters" do
    assert Paste.parse("?code=abc&state=xyz") == {:ok, %{"code" => "abc", "state" => "xyz"}}
  end

  test "a bare query string becomes its parameters" do
    assert Paste.parse("code=abc&state=xyz") == {:ok, %{"code" => "abc", "state" => "xyz"}}
  end

  test "a bare code is the code" do
    assert Paste.parse("abc-123_XYZ.4") == {:ok, %{"code" => "abc-123_XYZ.4"}}
    assert Paste.parse("  abc-123  ") == {:ok, %{"code" => "abc-123"}}
  end

  test "surrounding whitespace, angle brackets and a trailing # are tolerated" do
    assert Paste.parse("  <#{@url}?code=abc&state=xyz># \n") ==
             {:ok, %{"code" => "abc", "state" => "xyz"}}

    assert Paste.parse("<bare-code>\n") == {:ok, %{"code" => "bare-code"}}
  end

  # The exact callback an in-browser SIWC approval redirects to (the bug report's
  # "that text carries no authorization code" paste): a loopback callback with
  # `scope=` plus REAL codes, the issuer and the app's client id.
  @reported_url "http://localhost:1455/auth/callback?code=ac.1.AAApCOcLN1KblOS9Hs6gK85rmND5UPbcyPz19SIOqvopbPI4lLStK00R7X0w3LNz9t6ZCOdkiiYrbrAKxi0LCR3T92flcApKGyN86x5AzZGi4-v9CvguvvBmVGY&scope=openid+profile+email+offline_access&state=QobijGG4NozG_rxKnuiP3jnfglyGs7_rU7u1kBFDDCo&iss=https%3A%2F%2Fauth.openai.com&client_id=oaiapp_2d1b1c3d4e5f6a7b8c9d0e1f2a3b4c5d"
  @reported_code "ac.1.AAApCOcLN1KblOS9Hs6gK85rmND5UPbcyPz19SIOqvopbPI4lLStK00R7X0w3LNz9t6ZCOdkiiYrbrAKxi0LCR3T92flcApKGyN86x5AzZGi4-v9CvguvvBmVGY"
  @reported_state "QobijGG4NozG_rxKnuiP3jnfglyGs7_rU7u1kBFDDCo"
  test "the reported callback URL parses to its code and state" do
    assert Paste.parse(@reported_url) ==
             {:ok, %{"code" => @reported_code, "state" => @reported_state}}

    # A copy-pasted address bar value can arrive wrapped or space-padded.
    assert Paste.parse("  <#{@reported_url}>  ") ==
             {:ok, %{"code" => @reported_code, "state" => @reported_state}}

    # The bare authorization code the same browser shows is also accepted.
    assert Paste.parse(@reported_code) == {:ok, %{"code" => @reported_code}}
  end

  test "an error parameter is a denial, even beside a code (parity with the HTTP callback)" do
    assert Paste.parse("#{@url}?error=access_denied&state=xyz") == {:error, :authorization_denied}
    assert Paste.parse("error=access_denied&code=abc") == {:error, :authorization_denied}
    assert Paste.parse("?error=access_denied") == {:error, :authorization_denied}
  end

  test "text without a code is no_code" do
    assert Paste.parse("#{@url}?state=xyz") == {:error, :no_code}
    assert Paste.parse("state=xyz") == {:error, :no_code}
    assert Paste.parse("?code=&state=xyz") == {:error, :no_code}
    assert Paste.parse("") == {:error, :no_code}
    assert Paste.parse("   ") == {:error, :no_code}
    assert Paste.parse("not a code") == {:error, :no_code}
  end

  test "a path-only URL is never mistaken for a bare code" do
    assert Paste.parse(@url) == {:error, :no_code}
    assert Paste.parse("/auth/callback") == {:error, :no_code}
    assert Paste.parse("127.0.0.1:1455/auth/callback") == {:error, :no_code}
  end

  test "only the present code/state/error keys survive" do
    assert Paste.parse("#{@url}?code=abc&state=xyz&scope=openid&extra=1") ==
             {:ok, %{"code" => "abc", "state" => "xyz"}}
  end

  test "nil and non-binary input are no_code, never a raise" do
    assert Paste.parse(nil) == {:error, :no_code}
    assert Paste.parse(123) == {:error, :no_code}
    assert Paste.parse({:code, "abc"}) == {:error, :no_code}
  end
end
