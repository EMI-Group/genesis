# EvoGit CLI Layer — `lib/evo_git/cli/`

## Intent
Argument parsing and the interactive setup wizard for `EvoGit.CLI` (the parent-node module `../cli.ex` holds command dispatch).
Split out of `cli.ex` to keep parsing (pure) separate from dispatch (IO + task enqueue).
Both modules are pure/stdlib-only: no `System.cmd`, no `Port.open`, no `System.find_executable`, no filesystem writes of their own (config writes go through `EvoGit.Config`).

## API Surface
| File / function | Purpose |
|---|---|
| `parser.ex` `EvoGit.CLI.Parser.parse_args/1`, `parse_args_full/3` | `OptionParser.parse/3` wrapper. Switches: `help, version, file, path, model, mode, foreign_repo (keep), agent, node, starting_commit, archive, build_system`; aliases `h v f p m d R n b`. The `invalid` list is DISCARDED by `parse_args/1` — unknown flags and malformed values are silently ignored. |
| `parser.ex` `parse_model_flag/1` | `"id:provider:model"` → `{id, "provider:model"}`; anything else → `{nil, value}`. |
| `parser.ex` `maybe_put/3` | `nil` value → keyword unchanged. |
| `parser.ex` `parse_foreign_repos/1` | `-R` (repeatable) → `[%EvoGit.Core.ForeignRepo{}]`, READ-ONLY defaults (`writable: false`, `base_sha: nil`); `-R <id>:<path>` gives an explicit id, a bare path uses `Path.basename/1`. |
| `parser.ex` `split_foreign_repo_spec/1`, `drive_letter_abs_path?/1` | `id:path` split that never mistakes a Windows drive letter (`C:\...`, `D:/...`, matched by `~r/^[a-zA-Z]:[\\\/]/`) for an id. |
| `setup.ex` `EvoGit.CLI.Setup.run/0` | Provider → model → variant → API-key wizard; persists via `EvoGit.Config.save_user_config/1` + `save_credentials/1`. |
| `setup.ex` `do_add_model_profile/2` (`@doc false`) | Test wrapper for the private profile writer. |

## Constraints
- Parsing stays pure — no IO, no app-state reads, no env reads.
- Modes are STRINGS end-to-end (`"new"`/`"existing"`/`"simple"`/`"custom"`); `RuntimeOpts` raises on atoms.
- `-R` foreign repos from the CLI are always read-only; writable/`base_sha` is TOML-only (`genesis.toml`).
- `parse_args/1` calls give no feedback on unknown flags (`_invalid` dropped) — diagnostics live in `cli.ex` (`print_removed_flag_notices/1`).

## Known Issues

### `prompt_input/1` crashes on EOF (VERIFIED by execution)
`setup.ex:215-220` and `cli.ex:509-514` are identical:
```elixir
defp prompt_input(prompt) do
  case IO.gets(prompt) do
    nil -> ""
    input -> String.trim(input)
  end
end
```
`IO.gets/1` NEVER returns `nil` — it returns `:eof` at end of input or `{:error, reason}` (verified: `printf '' | elixir -e 'IO.inspect(IO.gets("p: "))'` → `:eof`), so the `nil -> ""` clause is dead and both EOF and error paths raise.
Verified: `String.trim(:eof)` → `** (FunctionClauseError) no function clause matching in String.trim/1`.
Every wizard prompt (`setup.ex:40,81,115,129,134,140,170`) and the genesis build-system prompt (`cli.ex:491`) routes through it.
Windows relevance: any invocation with stdin at EOF (spawned from a GUI wrapper, `subprocess(stdin=DEVNULL)`, a `.bat` with `< NUL`, a service) dies with an unhandled FunctionClauseError instead of degrading to the empty/default answer.
`cli.ex:407-419 confirm_non_empty_dir/0` has the same bug, unguarded: `IO.gets/1` → `:eof` is TRUTHY, so `String.trim(:eof)` crashes instead of the intended "abort" — trigger `--mode new -p <non-empty dir>` with EOF stdin.

### `stdin_tty?/0` probes the wrong device (stdout, not stdin)
`cli.ex:466-471` uses `:io.columns()` as the "is stdin interactive" test, but `:io.columns/0` reports the group leader's console width.
With stdout on a console and stdin at EOF it returns `{:ok, W}` → the build-system prompt runs → crashes per the issue above.
It is total (returns `{:error, :enotsup}` when not a console, never raises), so a fully-piped run is protected; a console-with-redirected-stdin run is not.

### `Setup.run/0` writes a DUPLICATE `[[llm.models]] id = "default"` profile on every re-run (VERIFIED by execution)
`EvoGit.Config.user_config/0` returns TOML-decoded STRING-keyed maps (verified: `%{"llm" => %{"models" => [%{"id" => "default", ...}]}}`).
`setup.ex:231-247 atomize_config_keys/1` recurses only through MAPS — the catch-all `atomize_config_keys(value), do: value` leaves the `models` LIST (and the maps inside it) string-keyed.
`setup.ex:291` then looks up the existing profile with `Map.get(p, :id) == "default"` → `nil` for a string-keyed profile → a second `id = "default"` profile is APPENDED.
Verified against the real compiled function: `EvoGit.CLI.do_add_model_profile(atomized_config, "openai:gpt-5")` on the real shape yields ids `["default", "default"]`.
`EvoGit.Config.Schema.validate/1` does not check id uniqueness (`config/ecto_validation.ex:372-374` accepts `:id` and `"id"`), so the write succeeds and the wizard prints "✓ Model saved to config.toml" — while runtime resolution keeps the FIRST entry (`config/schema/llm.ex:74` `Enum.find`, `:91-96` head-of-list), i.e. the stale model silently wins.
Test gap: `test/evo_git/cli_test.exs` only feeds ATOM-keyed configs (`%{llm: %{models: [%{id: "default", ...}]}}`), never the real string-keyed shape; `Setup.run/0` has no test.

### Windows-facing help text is POSIX-shell shaped
`cli.ex:645-659` teaches `mkdir -p`, `echo 'KEY = "..."' > credentials.toml` and `>>` appends — none of which work in `cmd.exe` (single quotes are not quoting), and the `echo` lines write into the CURRENT directory although the config file is read from `config_dir()`.
`cli.ex:596-598` and the root/`evo_git` CONTEXT examples use the same single-quoted `evogit run '<command>'` form, which under `cmd.exe` degenerates to a literal-quote argument.
The repo contains no `evogit` shim: the CLI is invoked as `mix run -e 'EvoGit.CLI.main(System.argv())' -- <cmd>` (dev only, not reachable from the desktop release).

### UTF-16LE config/credentials files are silently ignored
`EvoGit.Config.read_toml_file/3` (`config/config.ex:465-483`) → `TomlElixir.decode/1`; on error it logs a `Logger.warning` and returns `%{}`.
Verified: UTF-16LE input → `{:error, %TomlElixir.Parser.Error{reason: "Invalid UTF-8"}}`, while UTF-8-with-BOM and CRLF both decode fine (`deps/toml_elixir/lib/toml_elixir/parser.ex:20-40` strips a leading UTF-8 BOM).
Windows/`powershell.exe` 5.1 `>`/`Out-File` and some editor "Unicode" modes write UTF-16LE, so the documented manual-setup `echo ... > credentials.toml` step can yield an empty config (no API key / no model) with only a log warning as a signal.
`-f` prompt files degrade better: `../prompt_file.ex:30-42` rejects invalid UTF-8 with `{:error, {:not_text, ext}}` and a clear message.

### `-f` prompt files keep a leading UTF-8 BOM
`../prompt_file.ex:30-42` uses `String.valid?/1` + `String.trim/1`; a BOM is valid UTF-8 and `String.trim/1` does not strip U+FEFF (verified: `String.trim("\uFEFFhello\r\n")` → `"\uFEFFhello"`).
Files saved by Windows Notepad/VS Code as "UTF-8 with BOM" therefore prepend a zero-width no-break space to the objective. Silent, no crash.

## Notes for Agents
- Console output is cosmetic-risk only: `setup.ex:18-23` box-drawing and `setup.ex:91,190,196,199,207` `✓ ✅ ✗ ⚠` render as mojibake on a legacy Windows console code page, but `IO.puts/1` receives UTF-8 BINARIES (byte-transparent to a `latin1` device; erts substitutes unrepresentable chars in `unicode` mode) — no raise. `rel/vm.args.eex` sets no `+pc unicode`.
- Windows-safe by construction (do not re-audit): `-R` drive-letter/UNC splitting (`parser.ex:134-148`); `Path.basename/1`/`Path.expand/1` (they delegate to `:filename`, which is separator-aware per `:os.type()` — see Elixir's `path.ex`); TOML backslash escaping (`deps/toml_elixir/lib/toml_elixir/encoder.ex:101`) so Windows path values round-trip; `TomlElixir.encode/2` rescues encoder raises into `{:error, e}` (`deps/toml_elixir/lib/toml_elixir.ex:70-74`); `EvoGit.Config.save_user_config/1` + `save_credentials/1` use plain `File.write` (no temp+rename, so no Windows "rename over existing file" `:eacces` hazard) and surface failures as `{:error, reason}` printed by the wizard.
- `-R C:relative` (drive-relative, no separator after the colon) is NOT recognized as a path and mis-splits into `{:id, "C", "relative"}` — rare form, degrades to a later descriptive "not a git repository" error.
- The parent `../CONTEXT.md` is ~89 KB (over the per-file limit and read-truncated) — prefer this file plus `../cli.ex` source over that document for CLI details.
