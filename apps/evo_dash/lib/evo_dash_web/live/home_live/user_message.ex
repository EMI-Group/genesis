defmodule EvoDashWeb.HomeLive.UserMessage do
  @moduledoc """
  User chat bubble for the Home chat page (`EvoDashWeb.HomeLive`).

  A soft, right-aligned, content-fit bubble (DaisyUI theme tokens only —
  `bg-base-300`/`text-base-content` read correctly in both light and dark
  themes) with the message text left-aligned inside. Both typed sends and the
  empty-state suggestion chips produce the same `:user` transcript entry, so
  this component is the single user-bubble implementation.

  Total: every payload access is `Map.get`-guarded — nil/absent keys degrade
  instead of raising.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  attr(:entry, :map, required: true)

  def user_message(assigns) do
    ~H"""
    <div class="w-fit max-w-[85%] sm:max-w-[80%] rounded-3xl rounded-br-md bg-base-300 px-4 py-2.5 text-left text-[15px] leading-relaxed whitespace-pre-wrap break-words text-base-content shadow-sm">
      {Map.get(@entry, :text, "")}
    </div>
    """
  end
end
