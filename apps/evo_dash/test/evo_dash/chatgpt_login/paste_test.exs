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
