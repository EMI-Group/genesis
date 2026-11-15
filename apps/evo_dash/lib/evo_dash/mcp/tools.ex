defmodule EvoDash.MCP.Tools do
  @moduledoc "MCP transport adapter for the shared task tool catalog."

  defdelegate list(), to: EvoGit.TaskControl.Tools

  def call(name, args) do
    case EvoGit.TaskControl.Tools.call(name, args) do
      {:ok, data} -> {:ok, result(EvoDash.MCP.Links.enrich(data), false)}
      {:error, %{code: "invalid_arguments", message: message}} -> {:invalid, message}
      {:error, error} -> {:ok, result(%{error: error}, true)}
      {:invalid, message} -> {:invalid, message}
    end
  end

  defp result(data, failed) do
    %{
      content: [%{type: "text", text: Jason.encode!(data)}],
      structuredContent: data,
      isError: failed
    }
  end
end
