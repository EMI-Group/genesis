defmodule EvoDashWeb.SettingsLive.JsonObject do
  @moduledoc false

  # Callers own blank/map preprocessing and any field-error wrapping.
  def decode(raw, field) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:error, "#{field}_must_be_object"}
      {:error, _} -> {:error, "invalid_#{field}_json"}
    end
  end
end
