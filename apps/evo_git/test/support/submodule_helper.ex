defmodule EvoGit.TestSupport.Submodule do
  @moduledoc """
  Test helper for creating gitlink (submodule) entries WITHOUT cloning.

  Used by the worktree-creation tests to verify that gitlink/submodule
  entries are handled gracefully: excluded from CoW copy file lists and
  arriving in worktrees as empty placeholder dirs (same behavior as
  `git worktree add` — submodules are not auto-populated; users run
  `git submodule update --init`).
  """

  alias EvoGit.Adapters.Git

  @doc """
  Creates a nested git repo at `sub_path` inside `repo`, registers it in
  `.gitmodules`, and adds the gitlink (mode `160000`) to the superproject
  index via `git update-index --add --cacheinfo`.

  The nested repo's working tree stays populated (like a `git clone` that
  checked out the submodule), which is what triggers the CoW `cp` failure
  when gitlink paths leak into the copy list. No clone / no
  `protocol.file.allow` needed.

  Returns the nested repo's commit SHA (the gitlink oid). The caller is
  responsible for committing the superproject afterwards.
  """
  @spec add_gitlink(String.t(), String.t()) :: String.t()
  def add_gitlink(repo, sub_path) do
    sub_dir = Path.join(repo, sub_path)
    File.mkdir_p!(sub_dir)

    Git.init(sub_dir)
    Git.run(["config", "user.email", "test@example.com"], sub_dir)
    Git.run(["config", "user.name", "Test User"], sub_dir)
    Git.run(["config", "commit.gpgsign", "false"], sub_dir)

    File.write!(Path.join(sub_dir, "sub.txt"), "sub content")
    Git.add(sub_dir, "sub.txt")
    Git.commit(sub_dir, "Submodule init")

    {:ok, sub_sha} = Git.rev_parse(sub_dir, "HEAD")

    File.write!(
      Path.join(repo, ".gitmodules"),
      "[submodule \"#{sub_path}\"]\n\tpath = #{sub_path}\n\turl = ./#{sub_path}\n"
    )

    Git.add(repo, ".gitmodules")
    Git.run(["update-index", "--add", "--cacheinfo", "160000,#{sub_sha},#{sub_path}"], repo)
    sub_sha
  end
end
