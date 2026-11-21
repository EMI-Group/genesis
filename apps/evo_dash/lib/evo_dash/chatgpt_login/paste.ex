defmodule EvoDash.ChatGPTLogin.Paste do
  @moduledoc """
  Turns a pasted sign-in redirect back into the callback parameters of ONE `EvoDash.ChatGPTLogin.Flow`.
  The user's browser is often on a different machine than the Genesis host, so the SIWC redirect lands on the browser's OWN loopback and cannot reach the flow's listener; the address bar still holds the callback query, which the user can paste into Genesis instead.
  Every accepted shape is answered as a string-keyed parameter map — a full redirect URL (any scheme or host), a `?`-prefixed query string, a bare query string (`code=…&state=…`), or a bare authorization code.
  The parser is total and never raises: anything else (nil, a non-binary, a URL without a query, empty text) is `{:error, :no_code}`, because untrusted clipboard text must never crash the flow.
  """

  @param_keys ~w(code state error)

  # A bare paste is an authorization code, not prose: printable ASCII, no whitespace.
  @bare_code ~r/\A[!-~]+\z/

  @typedoc "The callback parameters a paste carries; only the present keys are returned."
  @type params :: %{optional(binary()) => binary()}

  @doc """
  Parses whatever the user pasted into callback parameters.

  An `error` parameter wins over a `code` (exactly like the HTTP callback, where a denial is a denial even when a code rides along), and text that carries neither is `{:error, :no_code}` so the attempt stays pending.
  """
  @spec parse(term()) :: {:ok, params()} | {:error, :authorization_denied | :no_code}
  def parse(input) when is_binary(input) do
    input
    |> normalize()
    |> extract()
    |> classify()
  end

  def parse(_input), do: {:error, :no_code}

  # A paste arrives with whatever the clipboard kept: padding whitespace, the
  # angle brackets of a copy-pasted link, and sometimes a trailing `#`.
  defp normalize(input) do
    input
    |> String.trim()
    |> String.trim_trailing("#")
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.trim()
  end

  defp extract(text) do
    case URI.parse(text) do
      %URI{query: query} when is_binary(query) and query != "" -> {:query, query}
      # A URL-shaped paste that lost its query is not a code: its scheme,
      # authority or path makes that unmistakable.
      %URI{scheme: scheme} when is_binary(scheme) -> :no_query
      %URI{host: host} when is_binary(host) -> :no_query
      %URI{authority: authority} when is_binary(authority) -> :no_query
      %URI{path: path} -> {:text, path}
    end
  end

  defp classify({:query, query}), do: params(query)
  defp classify(:no_query), do: {:error, :no_code}
  defp classify({:text, nil}), do: {:error, :no_code}
  defp classify({:text, ""}), do: {:error, :no_code}

  defp classify({:text, text}) do
    cond do
      String.contains?(text, "=") -> params(text)
      String.contains?(text, "/") -> {:error, :no_code}
      String.match?(text, @bare_code) -> {:ok, %{"code" => text}}
      true -> {:error, :no_code}
    end
  end

  defp params(query) do
    query
    |> URI.decode_query()
    |> Map.take(@param_keys)
    |> Map.filter(fn {_key, value} -> is_binary(value) and value != "" end)
    |> answer()
  end

  defp answer(%{"error" => _error}), do: {:error, :authorization_denied}
  defp answer(%{"code" => code} = params) when is_binary(code) and code != "", do: {:ok, params}
  defp answer(_params), do: {:error, :no_code}
end
