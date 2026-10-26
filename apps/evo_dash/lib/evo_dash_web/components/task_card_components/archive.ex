defmodule EvoDashWeb.TaskCardComponents.Archive do
  @moduledoc """
  Total readers for the lazily-fetched archive envelope (`detail.archive`) and
  the `opts[:archive]` opt-in check that decides whether the card's archive
  disclosure renders at all.
  """

  # ---------------------------------------------------------------------------
  # Helpers — lazy archive envelope (`detail.archive`)
  # ---------------------------------------------------------------------------
  #
  # Archive records are NOT on the summary map: they are fetched on demand via
  # the `load_task_archive` event. The envelope is
  # `%{state: :loading | :ok | :error, records: [map()], error: term(), seq:
  # pos_integer()}`. Every read below is TOTAL, so an odd shape falls back to
  # the empty/on-demand state instead of crashing the card.

  def archive_state(archive) do
    case archive do
      %{state: state} -> state
      %{"state" => state} -> state
      _ -> nil
    end
  end

  def archive_records(archive) do
    case archive do
      %{records: records} when is_list(records) -> records
      %{"records" => records} when is_list(records) -> records
      _ -> []
    end
  end

  # `opts[:archive]` is the archive OPT-IN signal (`true` from the dashboard,
  # `"true"` from the CLI/task data plane). The summary map cannot say whether
  # records actually exist, so this only decides whether the lazy disclosure
  # renders at all.
  def archive_opt?(opts) when is_list(opts) do
    Enum.find_value(opts, false, fn
      {:archive, value} -> value in [true, "true"]
      _ -> nil
    end)
  end

  def archive_opt?(_opts), do: false
end
