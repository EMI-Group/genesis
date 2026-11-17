# Task-Store Ecto Migrations

## Intent
These up-only Ecto migrations prepare `tasks.sqlite` before store access through `EvoGit.Store.Boot.run_migrations/1`.
Every migration executes in its own transaction and uses immediate `repo().query!/3` statements rather than queued `execute/1` commands.

## API Surface
The nine files expose distinct migration modules with `up/0`, loaded as ordered `{version, module}` pairs by Store.Boot.
Version 1 adopts tasks; 2 normalizes data; 3 and 4 create composite and covering indexes; 5 creates and fans out archives; 6 prunes redundant indexes; 7 creates VCT mounts and imports legacy projects; 8 adds session_mode; 9 adds pause_kind.

## Constraints
Versions 1 through 9 are frozen and must not be rewritten or renumbered.
Migration version 20260815000010 is retired and must not be reused.
Any future migration must use a unique module name and a version strictly above 20260815000010.

## Routing Table
This node has no child directories.
Tests live outside this node in `apps/evo_git/test/evo_git/store/` and are owned separately.
