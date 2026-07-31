# `scripts/e2e.sh` — live end-to-end test

Exercises every command group of the Linear CLI against a **real Linear workspace with a
real API key**. It creates issues, comments, a project and a milestone, then deletes them
again and proves they are gone.

Read the safety section before the first run.

```bash
./scripts/e2e.sh --team ENG            # full run, interactive confirmation
./scripts/e2e.sh --team ENG --dry-run  # read-only paths only, creates nothing
./scripts/e2e.sh --team ENG --yes      # non-interactive (CI, or a repeat run)
./scripts/e2e.sh --team ENG --verbose  # echo every invocation and its output
./scripts/e2e.sh --team ENG --keep     # leave everything behind for inspection
```

Exit status is `0` only when every case passed. Any failure, and any object that could
not be verified as deleted, makes it non-zero.

## Requirements

- The binary at `./zig-out/bin/linear` (override with `LINEAR_BIN=/path/to/linear`).
- A working credential — whatever `linear auth status` already reports is what gets used.
  The script never reads, writes, prints or logs the key itself.
- `jq` and `git` on `PATH`.
- `--team` is **required**. It is the blast radius, so the script refuses to infer it and
  will not fall back to `config.default_team_id`. Pass the team **key** (`ENG`); a uuid
  works too but produces a less readable run.

## Safety model

| Guarantee | How |
| --- | --- |
| Everything it creates is identifiable | Every title/name is prefixed `[e2e <RUN_ID>]`, where `RUN_ID` is `YYYYmmdd-HHMMSS-<pid>`. Nothing pre-existing can collide with it. |
| Everything it creates is deleted | Ids are appended to a tracking array as they are created; a `trap ... EXIT` walks it in reverse (dependency) order. This runs on success, on failure, and on Ctrl-C. |
| Cleanliness is proven, not assumed | After deleting, the run id is queried again via `search` and `projects list`. Anything still present is reported with its id and a copy-pasteable delete command, and the run exits non-zero. |
| Nothing else is ever touched | Every destructive call targets an id this run created, or a deliberate sentinel. There is no "delete everything matching e2e" path in the script. |
| Mutations are consented to | A summary of exactly what will be created is printed and an interactive `yes` is required before the first mutation. `--yes` skips it; without a terminal and without `--yes` the script refuses to mutate. |
| Your checkout is untouched | `issue start` and branch inference run inside a throwaway `git worktree` created under the scratch dir and removed on exit. Your working tree, your current branch and your uncommitted changes are never involved. |
| The key never leaks | No case ever passes `auth show --reveal`. Every captured output is passed through a `lin_api_[A-Za-z0-9_-]+` scrubber before it can be printed, and three cases assert that `auth show`, `auth show --json` and `auth status` contain no `lin_api_` substring. |

Two "a mutation escaped its guard" probes deliberately target
`00000000-0000-4000-8000-000000000000`, a syntactically valid uuid that cannot exist, so
that a regressed `--yes` check mutates nothing rather than mutating something real. The
bulk partial-failure case mixes in `E2ENOPE-999999`, an identifier whose team key cannot
exist.

### What a full run creates (and then deletes)

- 6 issues — lifecycle, stdin-description, parent, and 3 for the bulk case
- 3 comments on the lifecycle issue (one threaded reply, one multi-line body)
- 1 project, 1 milestone inside it
- 1 issue relation between two of the issues
- 1 local git worktree + the branch `issue start` checks out

Issue relations are not deleted directly — the CLI has no `issue unlink`. The relation
disappears with the issues, both of which carry the run id.

### If leftovers are reported

The verification query uses `search`, which does not request archived/trashed entities.
An issue the script deleted should therefore not come back. If one does, that is itself a
finding worth reporting — check the Linear trash in the UI before assuming the script
failed to clean up.

## Coverage

Each case prints `PASS` / `FAIL` / `SKIP` on its own line; failures print expected vs
actual plus the exact command, so a human can triage without re-running. `SKIP` is only
used for genuinely unavailable preconditions (no second page of issues, no non-terminal
workflow state, `--dry-run`), and the reason is always printed.

**preflight** — `--version`; binary/`jq`/`git` presence; detects `config.default_output`.

**security** — `--endpoint http://evil.example.com` rejected (and the reason is the
scheme); `--endpoint https://evil.example.com` rejected (and the reason is the host);
`auth show` and `auth show --json` contain no `lin_api_`; `issue update` without `--yes`
refused; `gql` mutation without `--yes` refused.

**auth** — `auth status`, `auth status --json` (asserts `key_present`/`key_valid`),
`auth test`, `auth test --json`. All four also assert the absence of `lin_api_`.

**read-only** — `me`, `me --json`, `teams list`, `teams list --json`, `labels list`,
`users list`, `users list --include-inactive`, `states list`, `projects list`,
`issues list`, `issues list --max-items/--sort/--human-time`, `search`,
`search --fields title,description,comments`, `issue view`.

**output modes** — on both `issues list` and `labels list`: default table (asserted to be
a table, not JSON), `--json`, `--fields` projection, `--quiet` (asserted to emit only
identifiers), `--data-only`, `--data-only --json`, `--plain`, `--no-truncate`. The
tab-separated shape checks additionally assert column counts, including that
`issues list --data-only` appends the url as a trailing column.

**pagination** — `issues list --limit 2 --pages 2` (JSON and table), the stderr page
summary, then a resume with `--cursor` that asserts the resumed page actually starts at a
different issue than page 1.

**issue lifecycle** — `issue create --description-file`, `issue create --description-file -`
(stdin), `issue view`, description round trips for both creation paths, `issue update
--title`, `--state` by name, `--parent` by identifier (each verified by reading the field
back), `issue link --related`, `issue delete --dry-run` (verified not to delete), and
`issue delete`.

**comments** — create, `--parent` threaded reply (parent verified through a round trip),
`--body-file` with a multi-line body, `issue comment list`, `update`, `delete`, and the
multi-line contract in all four output shapes: folded to one line in the table and in
`--data-only`, verbatim under `--json` and under `--data-only --json`.

**project** — `create`, `view`, `update --content-file` (read back through `gql`, since
`project view` does not expose `content`; asserted to exceed the 255-character
`description` cap), `update --name`, `add-issue`, `remove-issue`, `delete`.

**milestone** — `create`, `list`, `list --quiet`, `view`, `update`, `delete`, all against
the throwaway project.

**bulk** — creates 3 issues, runs `--bulk-stdin --dry-run` and verifies all 3 survive,
then deletes them via `--bulk-stdin` with one bogus id mixed in: asserts a non-zero exit,
the `bulk complete; 3 succeeded, 1 failed` summary line, and that the 3 valid ids really
were deleted.

**gql** — a plain query, `--dry-run`, `--paginate` over a connection with `--max-pages`,
`--vars` with inline JSON (used for the project content read-back), and the
mutation-without-`--yes` refusal (in the security phase).

**git workflow** — `issue id` / `url` / `title` / `describe` / `describe --references`
with an explicit identifier, then, inside a throwaway worktree, `issue start` followed by
the same commands with the identifier inferred from the branch name.

## Deliberately excluded

- **`issue pr`** — creates a real, externally visible pull request that this script
  cannot clean up. It is **not part of a normal run**. `--allow-pr` opts in; when it is
  set, `gh pr create` inherits the terminal and may prompt to push the branch, so the run
  needs a human watching it, and the PR must be closed manually afterwards.
- **`auth set`, `auth migrate`** — they rewrite the operator's credential storage. A test
  has no business moving someone's API key between backends.
- **`config set`, `config unset`** — they mutate the real config file. The script only
  *reads* `config show` (to detect `default_output=json`).
- **`download`, `issue view --attachment-dir`** — both need an existing
  `uploads.linear.app` attachment, which cannot be created through this CLI.
- **`issues list --all`** — an unbounded walk of a real workspace. `--pages`/`--cursor`
  cover the pagination logic without it.
- **`issue link --blocks` / `--duplicate`** — `--related` covers the same code path; the
  other two would only add objects to clean up.
- **`--config`, `--endpoint` (valid), `--retries`, `--timeout-ms`, `--no-keepalive`** —
  `--config` would bypass the credential helper that supplies the key; the rest are not
  observable from the outside.
- **Filter flags** `--assignee`, `--label`, `--state-id`, `--project`, `--milestone`,
  `--created-since`, `--updated-since`, `--sub-limit`, `--include-projects` — they need
  workspace-specific ids to be a meaningful assertion rather than an empty result.

## Notes for the operator

- The confirmation prompt appears **after** the read-only phases, so connectivity and
  auth are already proven before anything is created.
- `--keep` also keeps the scratch directory (every captured stdout/stderr, plus
  `commands.log` and `created.log`) and prints its path. It also keeps the git worktree
  and prints the two commands that remove it.
- If `config.default_output` is `json`, every command behaves as if `--json` were passed:
  `--data-only` emits JSON and the stderr pagination/bulk summaries are suppressed. The
  script detects this and skips exactly those shape cases with that reason, rather than
  failing on a valid configuration.
- `LINEAR_ALLOW_INSECURE_ENDPOINT` is unset for the run; leaving it armed would make the
  endpoint-allowlist cases vacuous.
