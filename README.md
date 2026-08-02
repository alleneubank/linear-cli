# Linear CLI (Zig)

Single-binary Linear client built with Zig 0.16.0. Uses stdlib only, defaults to human-readable tables with a `--json` override, and stores auth securely at `~/.config/linear/config.json` (0600). Use `linear help <command>` to see command-specific flags and examples.

## Build & Test
- Build: `zig build -Drelease-safe` (debug is default). Binary installs to `zig-out/bin/linear`.
- Tests: `zig build test`. Online suite runs with `LINEAR_ONLINE_TESTS=1`: `LINEAR_ONLINE_TESTS=1 LINEAR_TEST_TEAM_ID=<TEAM_ID> zig build online` (requires `LINEAR_API_KEY`; optional `LINEAR_TEST_ISSUE_ID`, `LINEAR_TEST_PROJECT_ID`, `LINEAR_TEST_MILESTONE_ID`; opt-in mutations with `LINEAR_TEST_ALLOW_MUTATIONS=1`).

## Manual QA (Live API)
- Quick start (uses a temp config): 
  ```
  export LINEAR_API_KEY=<paste key>
  export LINEAR_ONLINE_TESTS=1
  export LINEAR_TEST_TEAM_ID=<team-id>
  # Optional for broader coverage:
  # export LINEAR_TEST_ISSUE_ID=<identifier like ENG-123>
  # export LINEAR_TEST_PROJECT_ID=<project id>
  # export LINEAR_TEST_MILESTONE_ID=<milestone id>
  # export LINEAR_TEST_ALLOW_MUTATIONS=1  # enables create/delete tests
  rm -f /tmp/linear-cli-qa.json
  echo "$LINEAR_API_KEY" | ./zig-out/bin/linear --config /tmp/linear-cli-qa.json auth set
  ./zig-out/bin/linear --config /tmp/linear-cli-qa.json auth test
  zig build test
  LINEAR_ONLINE_TESTS=1 LINEAR_TEST_TEAM_ID=$LINEAR_TEST_TEAM_ID zig build online
  ```
- Finding IDs quickly:
  - Team: `./zig-out/bin/linear --config /tmp/linear-cli-qa.json teams list --json | jq -r '.nodes[0].id'`
  - Issue identifier: `./zig-out/bin/linear --config /tmp/linear-cli-qa.json issues list --limit 1 --quiet`
  - Project/milestone: `./zig-out/bin/linear --config /tmp/linear-cli-qa.json issues list --include-projects --fields project,milestone --limit 1 --json`
  - Label / assignee / workflow-state ids (for `--label`, `--assignee`, `--state-id`): `./zig-out/bin/linear --config /tmp/linear-cli-qa.json labels list --team <TEAM_KEY> --quiet`, `... users list --quiet`, `... states list --team <TEAM_KEY> --quiet`
  - If no suitable issue exists and mutations are allowed: `LINEAR_TEST_ALLOW_MUTATIONS=1 ./zig-out/bin/linear --config /tmp/linear-cli-qa.json issue create --team <TEAM_KEY_OR_ID> --title "CLI QA seed" --quiet`

## Config & Auth
- Config path: `~/.config/linear/config.json` (override with `--config PATH` or env `LINEAR_CONFIG`).
- API keys must be 4-512 characters from `[A-Za-z0-9_-]`; anything else is rejected at every ingestion point (config file, `LINEAR_API_KEY`, `auth set`, and every credential backend).
- Keys:
  - `api_key` — plaintext, **deprecated**; see [Credential backends](#credential-backends)
  - `credential_helper` — argv array for an external command that prints the key
  - `default_team_id` (default ``)
  - `default_output` (`table`|`json`, default `table`)
  - `default_state_filter` (default `["completed","canceled"]`)
  - `team_cache` (auto-populated key->id cache from `issue create`)
- Manage defaults without editing JSON: `linear config show`, `linear config set default_team_id ENG`, `linear config set default_output json`, `linear config unset default_state_filter`
- `config set default_team_id` verifies the team against the workspace before writing. An unknown team is refused and nothing is saved (`team 'X' not found in workspace`); a lookup that could not complete is reported separately (`could not verify team 'X'`) so a timeout is never mistaken for a verdict. There is no `--force`: use a per-command `--team` while offline.
- Files are created with 0600 perms inside a 0700 directory; the CLI warns if permissions drift. `auth show` prints a redacted key by default (`--redacted` is kept as a no-op alias); `auth show --reveal` prints the full token and is refused unless stdout is a terminal. `auth test` pings `viewer` to validate the current key.

### Credential backends

Resolution order, highest precedence first:

```
LINEAR_API_KEY  ->  credential_helper  ->  keychain (macOS)  ->  config file (deprecated)
```

Run `linear auth status` to see which one is actually supplying the key. It never prints the key itself, so it is safe in a terminal recording or a bug report. It is also fully offline: `format-valid (unverified)` means the key matched the expected charset and length, not that Linear accepted it. `linear auth test` is the only command that round-trips the credential against the API.

Only the config file is ever written back to disk. A key that came from the environment, a helper, or the keychain is never persisted, and a key already stored in the config file survives saves made while any of them is supplying the effective value.

**`credential_helper`** — an external command whose **stdout** is the API key. This is the portable backend: it works on every platform, and it covers 1Password, `pass`, `gopass`, `secret-tool`, Vault, and CI secret managers without any provider-specific code.

```jsonc
{
  "credential_helper": ["op", "read", "op://Private/Linear/api-key"]
}
```

- The array form is the documented one. It is **argv, not a command line**: no shell is spawned, so quotes, pipes, `;`, `$VAR`, and globs are ordinary bytes inside an argument, never syntax.
- A bare string (`"credential_helper": "pass show linear/api-key"`) is accepted for convenience and split on whitespace with the same no-shell rule. Quoting is not supported — use the array form when an argument contains a space.
- Configure it from the CLI with `linear config set credential_helper "op read op://Private/Linear/api-key"` — the string is split into argv by the same whitespace rule. The helper is **run once before it is stored** and must hand back a usable key; one that fails, prints nothing, or prints something that is not a key is refused and nothing is written. That check exists because a stored-but-broken helper clears the effective key instead of falling through, so saving one would lock you out. Bounds apply before anything is spawned: at most 16 arguments, 1024 bytes each. Nothing the helper writes to stdout is ever printed.
- This is the bootstrap path that keeps the key off disk entirely: put the key in your secret manager, point a helper at it, done. Nothing else needs to happen — there is no separate move-it-off-disk step, because the key was never on disk.
- Trailing whitespace and the newline every secret manager emits are trimmed, and the result is validated before it can reach an `Authorization` header.
- Failures are reported by exit status and stderr. The helper's **stdout is never logged, printed, or quoted in a diagnostic** — that is where the secret is.
- A helper that fails does **not** fall through to the config file. That would silently reinstate the plaintext key the helper was configured to replace, so the chain stops and the CLI reports the failure instead. `linear config unset credential_helper` still works in that state.
- Bounded: 30s timeout, 4 KiB of output. A hung helper is killed rather than hanging the CLI.

**macOS keychain** — used when no helper is configured. Write it with `linear auth set --to keychain`, which reads the key from piped stdin or a no-echo prompt and hands it to `/usr/bin/security -i` on **stdin**; the key never appears in an argv, where any process on the machine could read it out of the process table. The write is read back and compared before the command reports success. Reads run `/usr/bin/security find-generic-password -w -s linear-cli -a api-key`; the secret comes back on stdout, so nothing sensitive is in argv there either. A missing item is not an error, it just means the next backend gets its turn. On Linux and Windows this backend does not exist — `--to keychain` fails there rather than quietly writing the plaintext file.

```bash
op read op://Private/Linear/api-key | linear auth set --to keychain
linear auth status        # source: keychain
```

What the keychain actually buys you: **encryption at rest** and immunity to accidental disclosure — backups, synced folders, a stray `cat ~/.config/linear/config.json`, a screen share. It is **not** process isolation. The item is created through `security`, so it is ACL'd to `/usr/bin/security`, and any process running as you can read it back non-interactively without a prompt.

**Getting off the plaintext file:**

There is no migrate command. A key that has been in `config.json` has been on disk in cleartext, and no amount of overwriting beats copy-on-write filesystems, snapshots, Time Machine, or synced folders — so it has to be rotated regardless. Once you are rotating it anyway, moving the old key buys nothing over starting fresh, and starting fresh also clears the rest of the file's accumulated state.

```bash
# 1. Put the key in a secret manager, then rotate the old one in Linear. It has
#    been on disk in cleartext: treat it as disclosed.

# 2. Delete the config file. It also holds default_team_id and team_cache, so
#    those reset too.
rm ~/.config/linear/config.json

# 3. Set up again from scratch.
linear config set credential_helper "op read op://<vault>/<item>/<field>"
#    or, on macOS:  op read "op://<vault>/<item>/<field>" | linear auth set --to keychain
linear config set default_team_id TEAM_KEY
linear auth status && linear auth test
```

Delete before you configure, not after: `credential_helper` is stored *in* `config.json`, so setting it first and deleting the file afterwards would throw the new helper away with the old key. `--to keychain` is the exception — it writes nothing to the config file — but the order above works for both.

## CLI Overview
Global flags:
- `--json` — force JSON output (default follows `config.default_output`)
- `--config PATH` or env `LINEAR_CONFIG` — choose config file
- `--endpoint URL` — override the GraphQL endpoint (useful for QA/mocking). Must be `https` on host `api.linear.app`; set `LINEAR_ALLOW_INSECURE_ENDPOINT=1` to point at a local mock. Rejected endpoints exit non-zero before any request (the Authorization header is never sent off-allowlist).
- `--retries N` — retry 5xx responses up to N times with a small backoff
- `--timeout-ms MS` — request timeout flag (plumbed for future enforcement)
- `--no-keepalive` — disable HTTP keep-alive reuse
- `--help`/`--version` — version includes git hash and build mode
- `linear help <command>` — show command-specific help with examples

Commands:
- `auth set [--to keychain|file]` — store a key, read from piped stdin or a no-echo interactive prompt. There is no `--api-key` flag; keys are never accepted on argv. Fails when no key is supplied instead of persisting `LINEAR_API_KEY`. `--to keychain` writes the macOS keychain through `security -i` (stdin, never argv) and verifies a read-back; it fails on other platforms rather than falling back. `--to file` is the default and is **deprecated**: it stores the key in `config.json` in plaintext and every run that reads it says so. Prefer `config set credential_helper`, which keeps the key off disk entirely.
- `auth status [--json]` — report which backend supplied the key and whether it is *well-formed*, without ever printing the key and without touching the network. `key: present (format-valid, unverified)` is a charset/length check only — run `auth test` to verify the credential itself. JSON reports `key_present`, `key_format_valid`, and `key_verified` (always `null`; status never verifies). Exits non-zero when no well-formed key was found.
- `auth test` — ping `viewer` to validate the key.
- `auth show [--reveal]` — view the configured key; redacted unless `--reveal` is passed on a terminal.
- `config show|set|unset` — view or update CLI defaults (team/output/state filter) without editing JSON. `credential_helper` can be set, shown, and unset here; setting it runs the helper first and refuses to save one that does not return a usable key.
- `me` — show current user.
- `teams list [--fields id,key,name] [--plain] [--no-truncate]` — list teams with optional column and formatting controls.
- `labels list [--team ID|KEY] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--fields id,name,color,description,team] [--plain] [--no-truncate] [--quiet] [--data-only]` — list issue labels; supplies the raw ids required by `issues list --label` and `issue create --labels`.
- `users list [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--include-inactive] [--fields id,name,display_name,email,active] [--plain] [--no-truncate] [--quiet] [--data-only]` — list workspace members (active only unless `--include-inactive`); supplies the raw ids required by `issues list --assignee` and `issue create --assignee`.
- `states list [--team ID|KEY] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--fields id,name,type,position,team] [--plain] [--no-truncate] [--quiet] [--data-only]` — list workflow states; supplies the raw ids required by `issues list --state-id` and `issue create --state`. Workflow states are per-team and several teams commonly share state names, so the `Team` column is on by default to keep an unfiltered listing unambiguous.
- `search <query> [--team ID|KEY] [--search-fields title,description,comments] [--fields identifier,title,state,assignee,priority,updated] [--state-type TYPES] [--assignee USER_ID|me] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--case-sensitive] [--plain] [--no-truncate] [--quiet] [--data-only]` — server-side search over titles/descriptions/comments or identifiers (identifier filter matches issue numbers). Paginates with cursor support plus page summaries, like the other list commands.
  - The two field flags are separate: `--search-fields` chooses what is **searched** (`title`, `description`, `comments`; default `title,description`), `--fields` chooses which columns are **printed**, exactly as on `issues list`. `--fields` accepts the six columns `search` fetches — `identifier`, `title`, `state`, `assignee`, `priority`, `updated`; `parent`, `sub_issues`, `project` and `milestone` are not on a search response and are rejected with a pointer at `issues list` rather than printed as empty columns.
  - `--fields` used to mean "which fields to search". That meaning moved to `--search-fields` outright — there is no deprecated alias. A search-only value left in `--fields` (`description`, `comments`) is rejected locally, before any request, with a message naming `--search-fields`. `title` is the one value both flags accept, so a bare `--fields title` runs as a projection and prints a one-line note on stderr pointing at `--search-fields`.
- `download <URL> [--output FILE]` — fetch an `uploads.linear.app` attachment; `--output -` streams to stdout, otherwise the file is created 0600 like `issue view --attachment-dir` writes, since both carry private issue content.
- `issues list [--team ID|KEY] [--state TYPES] [--created-since TS] [--updated-since TS] [--project ID] [--milestone ID] [--sort FIELD[:asc|desc]] [--sort-nulls first|last] [--limit N] [--max-items N] [--sub-limit N] [--cursor CURSOR] [--pages N|--all] [--fields ...] [--include-projects] [--plain] [--no-truncate] [--human-time]` — defaults to the config team; excludes completed/canceled unless `--state` is provided; project/milestone filters available; parent/sub-issue columns stay opt-in — the `children` sub-query is only sent when `sub_issues` is in `--fields` or `--sub-limit` is passed explicitly, and `--sub-limit 0` disables it outright; `--include-projects` (or fields) adds project/milestone context; `--max-items` stops mid-page when needed; paginates with cursor support plus page summaries.
  - `--sort` takes any field Linear's `IssueSortInput` accepts, matched case-insensitively: `priority`, `estimate`, `title`, `label`, `labelGroup`, `slaStatus`, `createdAt`, `updatedAt`, `completedAt`, `dueDate`, `accumulatedStateUpdatedAt`, `cycle`, `milestone`, `assignee`, `delegate`, `project`, `team`, `manual`, `workflowState`, `customer`, `customerRevenue`, `customerCount`, `customerImportantCount`, `rootIssue`, `linkCount`, `release`. `created`/`updated` remain aliases for `createdAt`/`updatedAt`, and the direction suffix defaults to `desc`. An unknown field is rejected locally — the error prints the accepted list and no request is sent — and `linear help issues` prints the same list.
  - `--sort-nulls first|last` decides where issues with no value for the sort field land. It matters because most of the vocabulary is routinely null — `dueDate`, `completedAt`, `cycle`, `milestone`, `slaStatus`, `delegate`, `release`, and every `customer*` field on a non-customer issue — so a bounded page can fill up with nulls before the first real result:

    ```bash
    # Without it, a page of undated issues can arrive before the first deadline
    linear issues list --team ENG --sort dueDate:asc --limit 20

    # Soonest deadline first, undated issues pushed to the end
    linear issues list --team ENG --sort dueDate:asc --sort-nulls last --limit 20
    ```

    The value is matched case-insensitively (`LAST` works) and always sent lowercase, which is what Linear's `PaginationNulls` expects — note that `order` in the same object is capitalised (`Ascending`/`Descending`). Omitting the flag sends no `nulls` at all, leaving placement to the server default, so existing invocations are unchanged. `--sort-nulls` without `--sort` is an error, and an unknown value is rejected locally with the accepted values printed — neither costs a request.
- `issue view [ID|IDENTIFIER] [--fields LIST] [--quiet] [--data-only] [--human-time] [--sub-limit N] [--attachment-dir DIR]` — show a single issue; `--fields` filters output (identifier,title,state,assignee,priority,url,created_at,updated_at,description,project,milestone,parent,sub_issues); `--sub-limit` controls sub-issue expansion when requested; `--quiet` prints only the identifier, `--data-only` emits tab-separated fields or JSON. Attachment download is opt-in: nothing is written to disk unless `--attachment-dir DIR` is passed, and downloaded files are created 0600.
- `issue create --team ID|KEY --title TITLE [--description TEXT|--description-file PATH] [--priority N] [--state STATE_ID] [--assignee USER_ID] [--labels ID,ID] [--yes] [--quiet] [--data-only]` — resolves team key to id when needed, caches lookups, and returns identifier/url; requires `--yes`/`--force` to proceed (otherwise exits with a message).
- `issue update [ID|IDENTIFIER] [--assignee USER_ID|me] [--parent ID|IDENTIFIER] [--state STATE_ID|NAME] [--priority N] [--title TEXT] [--description TEXT|--description-file PATH] [--project PROJECT_ID] [--yes] [--quiet] [--data-only]` — updates one or more fields; requires `--yes`/`--force`.
- `issue delete <ID|IDENTIFIER> [--yes] [--dry-run] [--quiet] [--data-only]` — archives an issue by id/identifier; requires `--yes`/`--force` to proceed; `--dry-run` validates the target without sending the mutation and echoes the identifier/title. Accepts `--bulk ID,ID`, `--bulk-file PATH`, or `--bulk-stdin` instead of the positional identifier (see [Bulk deletes](#bulk-deletes)). There is no `--reason`: Linear's `issueDelete` takes only `(id, permanentlyDelete)`, so a reason could never be recorded on their side — record it yourself alongside the CLI's output.
- `issue comment [ID|IDENTIFIER] --body TEXT|--body-file PATH [--parent COMMENT_ID] [--yes]` — add a comment; `--parent` posts a threaded reply.
- `issue comment list [ID|IDENTIFIER] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--fields id,author,body,created_at,updated_at,parent,url] [--plain] [--no-truncate] [--quiet] [--data-only]` — read an issue's comments (including `parent` so thread structure survives a round trip). Paginates over the nested `Issue.comments` connection, so `--cursor` takes an `endCursor` from `.issue.comments.pageInfo`.
- `issue comment update <COMMENT_ID> --body TEXT|--body-file PATH [--yes] [--quiet] [--data-only]` / `issue comment delete <COMMENT_ID> [--yes] [--quiet] [--data-only]` — edit or remove a comment; both require `--yes`/`--force`.
- `project create --name NAME --team ID|KEY [--description TEXT] [--content TEXT|--content-file PATH] [--start-date DATE] [--target-date DATE] [--state STATE] [--yes]` / `project update <ID> [--name NAME] [--description TEXT] [--content TEXT|--content-file PATH] [--start-date DATE] [--target-date DATE] [--state STATE] [--yes]` — Linear caps `Project.description` at 255 characters, so long-form project text belongs in `--content`/`--content-file`, which map to the separate `Project.content` field.
- `issue start [ID|IDENTIFIER] [--branch NAME] [--from-ref REF] [--yes] [--quiet] [--data-only]` — checks out the issue's git branch and moves the issue into the team's first `started` workflow state; requires `--yes`/`--force`.
- `issue pr [ID|IDENTIFIER] [--base BRANCH] [--head BRANCH] [--draft] [--web] [--yes]` — runs `gh pr create` with `<IDENTIFIER> <title>` as the PR title and the Linear issue URL as the body; requires `--yes`/`--force`.
- `issue id|url|title [ID|IDENTIFIER]` — print one field on a single line, for shell substitution. `issue id` makes no API request.
- `issue describe [ID|IDENTIFIER] [--references]` — print a commit message body with `Linear-issue`/`Linear-issue-url` trailers, e.g. `git commit -m "$(linear issue describe)"`.
- `milestone list [--project ID|NAME] [--limit N] [--max-items N] [--cursor CURSOR] [--pages N|--all] [--fields id,name,target_date,sort_order,description,project] [--plain] [--no-truncate] [--quiet] [--data-only]` — list milestones; supplies the raw ids required by `issues list --milestone`. `--project` is optional: without it the listing spans every project in the workspace, with it the same query is filtered to that project. `--project` takes a project uuid, slug, or exact name; an ambiguous name is an error rather than a silent pick. Milestone names repeat across projects, so the `Project` column is on by default to keep an unfiltered listing unambiguous.
- `milestone view <ID> [--quiet] [--data-only]` — show one milestone with its project, target date, sort order, and description.
- `milestone create --project ID|NAME --name NAME [--description TEXT|--description-file PATH] [--target-date DATE] [--sort-order N] [--yes] [--quiet] [--data-only]` / `milestone update <ID> [--name NAME] [--description TEXT|--description-file PATH] [--target-date DATE] [--sort-order N] [--yes] [--quiet] [--data-only]` — create or edit a milestone; both require `--yes`/`--force`, and `update` requires at least one field flag. `--sort-order` is a float (lower sorts first).
- `milestone delete <ID> [--yes] [--dry-run] [--quiet] [--data-only]` — delete a milestone; requires `--yes`/`--force`. Also accepts `--bulk`/`--bulk-file`/`--bulk-stdin` (see [Bulk deletes](#bulk-deletes)).
- `gql [--query FILE] [--vars JSON|--vars-file FILE] [--operation-name NAME] [--fields LIST] [--data-only] [--paginate] [--max-pages N] [--yes] [--dry-run]` — arbitrary GraphQL; non-zero on HTTP/GraphQL errors. Documents containing a mutation operation require `--yes`/`--force`, matching the other mutating commands; `--dry-run` reports the operation without sending it and works with no API key configured (it makes no request). `--paginate` walks one connection to the end (see [GraphQL auto-pagination](#graphql-auto-pagination)).

### Git integration
`issue view`, `issue update`, `issue comment`, `issue comment list`, `issue link`, `issue start`, `issue pr`, `issue id`, `issue url`, `issue title`, and `issue describe` all take the issue identifier as an optional positional. When it is omitted the issue is inferred from the current branch: `git symbolic-ref --short HEAD`, then the leftmost `\b([A-Za-z0-9]+)-([1-9][0-9]*)\b` token in the branch name with the team key uppercased. A detached HEAD, a branch with no identifier, a missing `git`, and "not a git repository" each produce their own one-line diagnostic and a non-zero exit — the CLI never guesses.

`issue start` asks Linear for the issue's own `branchName` rather than slugifying the title locally, so branches match the ones Linear's "copy git branch name" button produces. `--branch NAME` overrides it, `--from-ref REF` bases a newly created branch on REF.

Everything this CLI spawns is built as an explicit argv array and executed without a shell: `git symbolic-ref --short HEAD`, `git rev-parse --is-inside-work-tree`, `git rev-parse --verify <branch>`, `git checkout <branch>`, `git checkout -b <branch> [<from-ref>]`, and `gh pr create --title <title> --body <url> [--base B] [--head H] [--draft] [--web]`. Issue titles and branch names are attacker-influenceable, so they only ever reach a child process as one discrete argument, and ref arguments that start with `-` or contain whitespace/control characters are rejected before the spawn. `gh` inherits stdio so its interactive prompts keep working; `git` output is captured and forwarded to stderr so stdout stays machine-readable.

### Bulk deletes
`issue delete` and `milestone delete` accept a batch instead of a positional id: `--bulk ID,ID,...`, `--bulk-file PATH` (one id per line or comma separated; `-` reads stdin), or `--bulk-stdin`. Only one source may be given, and combining a source with a positional id is an error.

The batch runs **serially** — one request at a time, in input order. These are destructive mutations, nothing else in this CLI runs concurrently, and a predictable order of deletes is worth more than the wall-clock saving a concurrent batcher would buy.

- Ids are deduplicated (first-seen order wins) so the same delete is never sent twice.
- A failed item is reported and the run continues; it does not abort the batch.
- A summary line (`issue delete: bulk complete; 2 succeeded, 1 failed`) goes to **stderr**, and is suppressed under `--json` so stdout stays the only thing a consumer parses.
- The exit code is non-zero when any item failed.
- `--dry-run` composes: a bulk dry run resolves and validates every id and sends no mutation.
- `--quiet` and `--data-only` keep their per-item meaning; under `--json` the per-item documents are wrapped in a single JSON array.
- A run is capped at 500 ids so a `--bulk-file` pointed at the wrong file fails with a diagnostic instead of firing thousands of deletes.

```bash
linear issues list --team ENG --state canceled --quiet | linear issue delete --bulk-stdin --dry-run
linear issue delete --bulk ENG-1,ENG-2 --yes --quiet
```

### GraphQL auto-pagination
`linear gql --paginate` follows one connection's cursor to the end and merges every page's `nodes` into the first page's document, so the output has the same shape as a single-page response with a longer `nodes` array and the final page's `pageInfo`.

The query must declare an `$after` variable, pass it to the connection, and select `pageInfo { hasNextPage endCursor }`. All three are checked against the document *before* the first request, so a query that cannot be walked fails with a diagnostic instead of quietly returning one page. Mutations are rejected outright.

The connection is discovered in the response breadth-first, so the shallowest object selecting both `nodes` and `pageInfo` is the one that gets walked; a connection nested inside an array is not eligible (there is no single stable path to merge into). `--max-pages N` bounds the walk (default 20) so a malformed query cannot loop forever; hitting the bound prints a warning on stderr and still returns the pages it collected with `hasNextPage: true` intact.

```bash
linear gql --query issues.graphql --vars '{"teamId":"..."}' --paginate --max-pages 5 --data-only
```

### Long-form content from files
Every text field that can carry multi-KB markdown accepts a companion `--*-file PATH` flag (`--description-file`, `--body-file`, `--content-file`). `PATH` may be `-` to read stdin. This avoids the shell-quoting corruption that argv-passed bodies are prone to (embedded quotes, newlines, `$`). Passing both the inline flag and its `-file` companion is an error rather than a silent precedence rule, and inputs above 1 MiB are rejected with an explicit diagnostic.

## Output
- Tables for lists; key/value blocks for detail views.
- `--json` prints parsed JSON (gql honors `--fields` when present).
 - `issues list --json` adds top-level `pageInfo` plus limit/sort metadata (and `maxItems` when set); `--data-only --json` emits a nodes array with a sibling `pageInfo`.
- `--plain` disables padding/truncation; `--no-truncate` keeps full cell text.
- `--human-time` renders issue timestamps relative to now.
- `--data-only` on `issue view|create` emits tab-separated fields (or JSON); `--quiet` prints only the identifier. On `gql`, `--data-only` strips the GraphQL envelope.
- `issue comment list` folds newlines and tabs inside a comment body to spaces for table and tab-separated output, because both are single-line record formats; `--json` (with or without `--data-only`) returns bodies verbatim.
- Bulk deletes wrap their per-item `--json` documents in one array and move the batch summary to stderr, so `--json` output stays a single parseable document.

## GraphQL Client
- Endpoint: `https://api.linear.app/graphql`.
- Auth header: `Authorization: <key>` (no Bearer).
- Shared HTTP client with keep-alive (toggle with `--no-keepalive`).
- Retries 5xx responses with a small backoff; timeout flag is wired for future use.
- Surfaces HTTP status and first GraphQL error when available; 401s nudge to set `LINEAR_API_KEY` or run `auth set`.

## Defaults
- Default team id: ``.
- Default output: table.
- Default state exclusion: `completed`, `canceled`.
- Pagination: `issues list` and `search` fetch 25 items per page, the other list commands 50; `--cursor`, `--pages`, and `--all` drive additional page fetches, `--max-items` caps the total (it may truncate mid-page), and stderr reports fetched counts plus the `--cursor` value to resume from. The summary is suppressed under `--json`. Every list command paginates, including `search` and `issue comment list`; the latter walks a nested connection, so its cursors come from `.issue.comments.pageInfo`.

## Claude Code Integration

Install as a Claude Code plugin to let Claude manage Linear issues for you.

### Prerequisites

Install the `linear` binary first:
```bash
npm install -g @0xbigboss/linear-cli
linear auth set  # configure your API key
```

### Install the Plugin

**1. Add the marketplace:**
```
/plugin marketplace add https://github.com/0xbigboss/linear-cli
```

**2. Install the plugin:**
```
/plugin install linear-cli@linear-cli-marketplace
```

**3. Restart Claude Code** to load the plugin.

### What It Does

The plugin provides a skill that teaches Claude how to use the Linear CLI. Once installed, Claude will automatically use the CLI when you ask about:
- Listing, viewing, or creating issues
- Managing teams and projects
- Linking issues, adding attachments, or comments
- Any Linear-related task

Example prompts:
- "List my Linear issues"
- "Create an issue in the ENG team titled 'Fix login bug'"
- "Show me issue ENG-123"
- "Link ENG-123 as blocking ENG-456"
