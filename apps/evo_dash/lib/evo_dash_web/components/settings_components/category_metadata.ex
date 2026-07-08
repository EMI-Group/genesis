defmodule EvoDashWeb.SettingsComponents.CategoryMetadata do
  @moduledoc """
  Pure helper functions for category display names, icons, descriptions,
  sorting, search matching, and API key prefix hints.

  This module has NO HEEx templates and does NOT need `use EvoDashWeb, :html`.
  It uses `use Gettext, backend: EvoDashWeb.Gettext` for gettext macros.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  # ── Public API ──

  def category_display_name(:scheduler), do: gettext("Scheduler")
  def category_display_name(:llm), do: gettext("LLM")
  def category_display_name(:user), do: gettext("User")
  def category_display_name(:git), do: gettext("Git")
  def category_display_name(:sandbox), do: gettext("Sandbox")
  def category_display_name(:truncation), do: gettext("Truncation")
  def category_display_name(:task_history), do: gettext("Task History")
  def category_display_name(:tools), do: gettext("Tools")
  def category_display_name(:server), do: gettext("Server")
  def category_display_name(:nix), do: gettext("Nix")

  def category_icon(:scheduler), do: "hero-cog-6-tooth"
  def category_icon(:llm), do: "hero-sparkles"
  def category_icon(:user), do: "hero-user"
  def category_icon(:git), do: "brand-git"
  def category_icon(:sandbox), do: "hero-shield-check"
  def category_icon(:truncation), do: "hero-scissors"
  def category_icon(:task_history), do: "hero-clock"
  def category_icon(:tools), do: "hero-wrench-screwdriver"
  def category_icon(:server), do: "hero-server"
  def category_icon(:nix), do: "brand-nix"

  # Made public because category_section/1 in the parent module calls it.
  def category_description(:scheduler),
    do: gettext("Control agent concurrency, retry behavior, and depth limits.")

  def category_description(:llm),
    do: gettext("Configure the language model provider and token compression.")

  def category_description(:user),
    do: gettext("Set your user identity for Git commits and collaboration.")

  def category_description(:git),
    do: gettext("Configure Git commit behavior and attribution for agent-generated commits.")

  def category_description(:sandbox),
    do: gettext("Manage sandbox isolation, resource limits, and process constraints.")

  def category_description(:truncation),
    do: gettext("Configure output truncation limits for tool and context windows.")

  def category_description(:task_history),
    do: gettext("Manage how many past tasks are retained and for how long.")

  def category_description(:tools),
    do: gettext("Configure external tool integrations such as web search.")

  def category_description(:server),
    do: gettext("Configure the web dashboard listen address and port.")

  def category_description(:nix),
    do: gettext("Configure Nix develop environment integration for tool calls.")

  def schema_matches?(_schema, ""), do: true

  def schema_matches?(schema, search_text) do
    lower = String.downcase(search_text)

    String.contains?(String.downcase(Enum.join(schema.key_path, ".")), lower) or
      String.contains?(String.downcase(schema.description), lower)
  end

  # Made public because category_section/1 in the parent module calls it.
  def api_key_prefix_hint(:openai), do: "sk-proj-..."
  def api_key_prefix_hint(:anthropic), do: "sk-ant-api03-..."
  def api_key_prefix_hint(:google), do: "AIzaSy..."
  def api_key_prefix_hint(:deepseek), do: "sk-..."
  def api_key_prefix_hint(:alibaba), do: "sk-..."
  def api_key_prefix_hint(:zai), do: gettext("No prefix (hexadecimal)")
  def api_key_prefix_hint(:minimax), do: "sk-cp-... or sk-..."
  def api_key_prefix_hint(_other), do: nil

  # ── Helpers shared by sidebar and search_results ──

  def sort_categories(categories) do
    order = [
      :llm,
      :scheduler,
      :user,
      :git,
      :sandbox,
      :truncation,
      :task_history,
      :server,
      :tools,
      :nix
    ]

    Enum.sort_by(categories, fn {cat, _} -> Enum.find_index(order, &(&1 == cat)) || 99 end)
  end

  def category_match_count(_category, schemas, search_text) do
    Enum.count(schemas, &schema_matches?(&1, search_text))
  end
end
