defmodule EvoGit.Store.Operations.Decoding do
  @moduledoc """
  The ONE skip-and-log row-decode boundary for the Operations modules that
  must never fail a whole read because of one bad row.

  ## Why a rescue is the right shape here

  Every store read hands the RAW wire values SQLite stored to a Codec decoder,
  and those decoders RAISE by design on corrupt or legacy data (e.g.
  `EvoGit.Store.Codec.decode_opts/1` raises `ArgumentError` on non-object
  `opts` JSON). A real database can hold such a row — a pre-migration or
  hand-edited database, a partially written blob — so a page decode must be
  able to skip exactly the offending row and keep every other one. This module
  is that deliberate RECOVERY boundary: the rescue is scoped to ONE row's
  decode call, it logs what it skipped, and it contributes NOTHING for that
  row.

  It deliberately does NOT catch query or database errors: only
  `decoder.(row)` sits inside the `try`, so a raising query, an Ecto loader
  failure or a raising `id_fun` propagates unchanged to the caller (the crash
  philosophy the Operations modules follow).

  ## Warning format

  Exactly ONE `Logger.warning` per skipped row:

      Store: skipping undecodable row in <table> (id: <inspected id>): <message>

  The text is the pre-extraction spelling, so operators (and log greps) see no
  change.
  """

  require Logger

  @doc """
  Decodes every row in `rows` through `decoder`, SKIPPING (and logging) each
  row whose decode raises; the skipped row contributes nothing to the result.

  `table` is the table name used in the warning, `id_fun` extracts one row's
  id for that warning (evaluated per row OUTSIDE the rescue boundary, so a
  raising id extractor is a programming error that surfaces instead of being
  swallowed), and `decoder` decodes one row and RAISES on corrupt data by
  design.
  """
  @spec decode_skipping_bad([map()], String.t(), (map() -> term()), (map() -> term())) ::
          [term()]
  def decode_skipping_bad(rows, table, id_fun, decoder)
      when is_list(rows) and is_function(id_fun, 1) and is_function(decoder, 1) do
    Enum.flat_map(rows, fn row ->
      # Justified try/rescue — the per-row decode boundary: DB rows may contain
      # corrupt or legacy data that fails to decode, and the Codec decoders
      # raise by design, so skipping (and logging) the offending row is the
      # deliberate recovery path. ONLY the decode call is guarded — never the
      # query and never the id extraction.
      id = id_fun.(row)

      try do
        [decoder.(row)]
      rescue
        e ->
          Logger.warning(
            "Store: skipping undecodable row in #{table} (id: #{inspect(id)}): " <>
              Exception.message(e)
          )

          []
      end
    end)
  end
end
