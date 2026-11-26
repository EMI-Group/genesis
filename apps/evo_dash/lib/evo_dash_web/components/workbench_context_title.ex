defmodule EvoDashWeb.WorkbenchContextTitle do
  @moduledoc false
  use EvoDashWeb, :html

  alias EvoGit.Util.Strings

  def label(assigns, target) do
    scope_name(assigns, target) || page_label(assigns.current_page)
  end

  defp scope_name(%{workbench_context_name: name, workbench_project: path} = assigns, target) do
    if not is_nil(target) and scoped_page?(assigns) do
      cond do
        nonblank?(name) -> name
        nonblank?(path) -> Path.basename(path)
        true -> nil
      end
    end
  end

  defp scoped_page?(%{current_page: page}) when page in [:dashboard, :assistant], do: true

  defp scoped_page?(%{current_page: page, workbench_task: task, workbench_project: project})
       when page in [:agents, :tasks, :review],
       do: nonblank?(task) and nonblank?(project)

  defp scoped_page?(_), do: false

  defp nonblank?(value), do: is_binary(value) and Strings.present?(value)

  def page_label(:dashboard), do: gettext("Projects")
  def page_label(:phx_dashboard), do: gettext("System Dashboard")
  def page_label(:agents), do: gettext("Agents")
  def page_label(:tasks), do: gettext("Tasks")

  # zh_CN: "进程" — 指 Genesis 跟踪的操作系统进程（智能体工具调用与后台任务），不是 Erlang 进程
  def page_label(:processes), do: gettext("Processes")
  def page_label(:settings), do: gettext("Settings")
  def page_label(:system), do: gettext("System")
  def page_label(:assistant), do: gettext("Assistant")
  def page_label(:review), do: gettext("Review")
  def page_label(:welcome), do: gettext("Welcome to Genesis")
  def page_label(_), do: nil
end
