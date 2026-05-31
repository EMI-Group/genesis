defmodule EvoDashWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext),
  your module gains a set of macros for translations. See
  the [Gettext Docs](https://hexdocs.pm/gettext/gettext.html) for detailed usage.
  """
  use Gettext.Backend, otp_app: :evo_dash
end
