defmodule EvoDash.Test.PersistedConfig do
  @moduledoc """
  The Settings suites' ONE way to read the config that was actually PERSISTED,
  pinned to the current bytes of the test's own config directory.

  `EvoGit.Config.user_config/0` answers from the BEAM-global `:persistent_term`
  snapshot `EvoGit.Config.Cache` keeps per config DIRECTORY: the map is shared
  by every process in the VM that resolves that directory, and its `generation`
  is replaced by whichever refresh stored last (a save's synchronous reload, an
  explicit `Cache.reload/0,1`, or a `Cache.get/1` miss build). A Settings pin
  that asserts what a save persisted therefore must not ask "which snapshot
  happens to be stored right now" — it must ask "what does the config directory
  hold now" — and `EvoGit.Config.Cache.reload/0` is exactly that question: it
  BUILDS a snapshot from the directory's current bytes and answers with the
  build it just made (or the stored snapshot only when the stored and the built
  fingerprint — i.e. the content — are identical). The value is correct even
  when another process stores a different snapshot immediately afterwards.

  It reads through the production RAM path (`EvoGit.Config.Cache`), so the pin
  still covers the snapshot the dashboard itself reads; the only thing it
  removes is the dependence on a store ORDER the test does not own.
  The directory is resolved at call time in the calling process, so the
  per-test `EvoDash.Test.ConfigDir` override keeps this isolated: the reload
  only ever touches the calling test's own directory and never another test's
  or the developer's real `~/.config/genesis`.
  """

  @doc """
  Returns the persisted user config of the CALLING process' config directory,
  read from the directory's current bytes.
  """
  @spec user_config() :: map()
  def user_config, do: EvoGit.Config.Cache.reload().user_config
end
