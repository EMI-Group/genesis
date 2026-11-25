# Required by both layout suites so each can run independently.
defmodule EvoDashWeb.LayoutsTest.Helpers do
  @moduledoc false

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  alias EvoDashWeb.Layouts

  def assert_classes(node, expected) do
    classes = node |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
    for class <- expected, do: assert(class in classes)
  end

  # Renders the full app layout shell. `flash` + `inner_block` are the only
  # assigns a bare render needs; every other attribute is optional with a
  # default (see the `attr` declarations at the top of layouts.ex).
  def render_app(assigns) do
    render_component(
      &Layouts.app/1,
      Keyword.merge(
        [
          flash: %{},
          inner_block: [%{inner_block: fn _changed, _argument -> "Page content" end}]
        ],
        assigns
      )
    )
  end

  # Task rows of the ACTIVE Tasks section — live tasks only, so a finished
  # review candidate is counted by `review_task_links/1` instead.
  def sidebar_task_links(html) do
    html |> parse() |> Floki.find("#workbench-active-tasks [data-sidebar-task-link]") |> length()
  end

  # Element children of a parsed Floki node (text nodes dropped).
  def element_children({_tag, _attrs, children}), do: Enum.reject(children, &is_binary/1)

  # Ancestor chain (root first) of the FIRST node matching `fun`, found by an
  # explicit tree walk because Floki exposes no parent accessor. This is what
  # turns "not nested in a disclosure" into a structural claim instead of a text check.
  def ancestors_where(tree, fun) do
    case walk_to_match(tree, fun, []) do
      {:ok, ancestors} -> ancestors
      :error -> flunk("no node matched the structural search")
    end
  end

  defp walk_to_match(nodes, fun, ancestors) when is_list(nodes) do
    Enum.reduce_while(nodes, :error, fn node, :error ->
      case walk_to_match(node, fun, ancestors) do
        {:ok, ancestors} -> {:halt, {:ok, ancestors}}
        :error -> {:cont, :error}
      end
    end)
  end

  defp walk_to_match(node, fun, ancestors) when is_tuple(node) do
    if fun.(node) do
      {:ok, ancestors}
    else
      walk_to_match(element_children(node), fun, ancestors ++ [node])
    end
  end

  defp walk_to_match(_text_node, _fun, _ancestors), do: :error

  def has_id?(node, id), do: Floki.attribute(node, "id") == [id]

  def has_class?(node, class) do
    node
    |> Floki.attribute("class")
    |> Enum.join(" ")
    |> String.split()
    |> Enum.member?(class)
  end

  # A task summary entry as the Active Tasks hub hands it to the sidebar. The
  # `:session_mode` key is only added when a test supplies it, so the "missing
  # key = one-shot" defensive default stays exercised.
  def task(attrs) do
    entry = %{
      id: Keyword.fetch!(attrs, :id),
      status: Keyword.fetch!(attrs, :status),
      project_path: Keyword.get(attrs, :project_path),
      started_at: DateTime.utc_now(),
      finished_at: Keyword.get(attrs, :finished_at),
      opts: [objective: Keyword.fetch!(attrs, :objective)]
    }

    case Keyword.fetch(attrs, :session_mode) do
      {:ok, session_mode} -> Map.put(entry, :session_mode, session_mode)
      :error -> entry
    end
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  def parse(html), do: Floki.parse_document!(html)
end
