defmodule EvoDashWeb.Plugs.Locale do
  @moduledoc """
  A Plug that sets the Gettext locale for each request.

  Locale resolution order:
    1. `locale` cookie (if present and valid)
    2. `accept-language` request header (best match)
    3. Default: `"en"`
  """

  import Plug.Conn

  @supported_languages %{
    "ar" => "Arabic العربية",
    "de" => "German Deutsch",
    "en" => "English",
    "zh_CN" => "Chinese (Simplified) 中文 (简体)",
    "zh_HK" => "Chinese (Traditional) 中文 (繁體)",
    "ja" => "Japanese 日本語",
    "es" => "Spanish español",
    "ru" => "Russian русский",
    "pt" => "Portuguese português",
    "id" => "Indonesian Bahasa Indonesia",
    "ko" => "Korean 한국어",
    "th" => "Thai ภาษาไทย",
    "vi" => "Vietnamese Tiếng Việt",
    "fr" => "French Français",
    "it" => "Italian Italiano"
  }

  @default_locale "en"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    locale =
      conn
      |> get_cookie_locale()
      |> Kernel.||(get_accept_language_locale(conn))
      |> Kernel.||(@default_locale)

    Gettext.put_locale(EvoDashWeb.Gettext, locale)

    conn
    |> put_private(:locale, locale)
    |> put_session(:locale, locale)
  end

  defp get_cookie_locale(conn) do
    case conn.cookies["locale"] do
      nil -> nil
      cookie when is_binary(cookie) -> if Map.has_key?(@supported_languages, cookie), do: cookie
    end
  end

  defp get_accept_language_locale(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] ->
        header
        |> parse_accept_language()
        |> find_best_match()

      _ ->
        nil
    end
  end

  # Parse the Accept-Language header into a list of {tag, quality} tuples,
  # sorted by quality descending.
  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn part ->
      case String.split(part, ";") do
        [tag] ->
          {tag, 1.0}

        [tag, q_part] ->
          q =
            case Float.parse(String.replace(q_part, "q=", "")) do
              {val, _} -> val
              :error -> 1.0
            end

          {tag, q}
      end
    end)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
  end

  # Find the first language tag that matches a supported language.
  # Normalizes dashes to underscores and maps short codes (e.g. "zh" → "zh_CN").
  defp find_best_match(tags) do
    Enum.find_value(tags, fn {tag, _q} ->
      normalized = String.replace(tag, "-", "_")

      # Direct match
      if Map.has_key?(@supported_languages, normalized) do
        normalized
      else
        # Try mapping short primary tags
        primary = normalized |> String.split("_") |> hd()

        case primary do
          "zh" -> "zh_CN"
          _ -> if Map.has_key?(@supported_languages, primary), do: primary
        end
      end
    end)
  end
end
