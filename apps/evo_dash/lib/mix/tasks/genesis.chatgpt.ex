defmodule Mix.Tasks.Genesis.Chatgpt do
  use Mix.Task

  @shortdoc "Connect a ChatGPT subscription"
  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    case EvoDash.ChatGPTCLI.run(args) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("ChatGPT: #{inspect(reason)}")
    end
  end
end
