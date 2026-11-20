defmodule EvoDashWeb.LLMSetup.ChatGPT do
  @moduledoc "ChatGPT account selection and model metadata shared by the setup flows."

  alias EvoGit.Auth.ChatGPT.Store

  def provider?(provider), do: provider in [:openai_codex, "openai_codex"]

  def accounts(target_node) when target_node == node(), do: Store.accounts()

  def accounts(target_node) do
    case EvoDash.NodeContext.call_remote(target_node, Store, :accounts, []) do
      {:ok, accounts} when is_map(accounts) -> accounts
      _ -> %{}
    end
  end

  def account_name(account) when is_binary(account) and account != "", do: account
  def account_name(_account), do: Store.default_account()

  def model_entries(accounts, account) do
    accounts
    |> Map.get(account_name(account), %{})
    |> Map.get(:models, [])
    |> Enum.map(fn %{"slug" => slug, "display_name" => label} ->
      %{id: slug, display_name: label}
    end)
  end

  def available_model?(accounts, account, model) do
    Enum.any?(model_entries(accounts, account), &(&1.id == model))
  end
end
