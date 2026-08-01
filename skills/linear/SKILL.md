---
name: linear
description: Manages Linear issues, teams, projects, and milestones via CLI. Lists issues, creates tasks, views details, links issues, enumerates labels/users/workflow states, reads and edits comments, drives the git branch workflow, and runs GraphQL queries. Must use for "my Linear issues", "create Linear task", "link issues in Linear", "Linear API query", or any Linear project management request.
allowed-tools: Bash(linear:*), Bash(jq:*), Bash(grep:*), Bash(cat:*), Bash(curl:*)
---

# Linear CLI

Interacts with Linear for issue tracking and project management using the `linear` command.

## Scope
- Use for Linear issue/project/teams management via the CLI or GraphQL (`linear gql`).
- Prefer built-in commands over raw GraphQL unless functionality is missing.
- Keep defaults in sync with the user's config; do not hard-code team IDs/outputs.

## Branch Inference — the ID argument is usually optional

Inside a git repo, these commands read the current branch and extract a `TEAM-123` identifier from it,
so the positional ID can be **omitted**:

| Command | With inference |
|---------|----------------|
| `issue view` | `linear issue view --fields identifier,state --data-only` |
| `issue update` | `linear issue update --assignee me --yes` |
| `issue link` | `linear issue link --blocks ENG-456 --yes` |
| `issue comment` | `linear issue comment --body "..." --yes --quiet` |
| `issue comment list` | `linear issue comment list --limit 20 --json` |
| `issue start`, `issue pr` | `linear issue start --yes`, `linear issue pr --yes` |
| `issue id`, `issue url`, `issue title`, `issue describe` | `linear issue id` |

The match is the leftmost `\b([A-Za-z0-9]+)-([1-9][0-9]*)\b` in the branch name, team key uppercased —
the same convention as Linear's own `Issue.branchName`, so a branch made with "copy git branch name"
resolves. Two consequences are deliberate: `_` is a word character (`feat_eng-123` does **not** match),
and a leading zero is not a valid number (`eng-0123` does **not** match).

`issue delete` is **not** in this list — it always needs an explicit target (or `--bulk`).

When inference cannot answer, the command fails on stderr rather than guessing:

```
issue view: branch 'main' has no issue identifier; pass one explicitly
issue view: HEAD is detached; pass an issue identifier explicitly
issue view: not a git repository; pass an issue identifier explicitly
issue view: git was not found on PATH; pass an issue identifier explicitly
```

**Pass the identifier explicitly whenever the branch is not the issue you mean.** Inference is a
convenience for work-in-progress, not a substitute for naming the target in a script.

## Token Discipline

Default output is verbose. The output-reducing flags below are the main reason to use this CLI over raw
GraphQL. Reach for them on every call.

**Read this first — two costs that are on by default:**

1. `linear issues list` adds `children(first: 10)` to the query for *every* row, even when `sub_issues`
   is not in `--fields`. `--sub-limit 0` removes the sub-query entirely.
2. `linear issue view` always fetches the description, regardless of `--fields` — the query selects it
   unconditionally. Use `gql` when you want the issue without its description.

Attachment downloading is **not** one of these costs any more. `issue view` writes nothing to disk unless
you pass `--attachment-dir DIR`; there is no default directory and no `/tmp` fallback. Pass the flag only
when you actually want the files.

### Output-reducing flags

| Flag | Available on | Default | Effect |
|------|--------------|---------|--------|
| `--fields LIST` | `issues list`, `issue view`, `issue comment list`, `projects list`, `project view`, `teams list`, `labels list`, `users list`, `states list`, `milestone list`, `gql` | command-specific (below) | Projection — print only these fields |
| `--quiet` | `issues list`, `issue view`, `issue create`, `issue update`, `issue delete`, `issue link`, `issue comment`, `issue comment list`/`update`/`delete`, `issue start`, `project add-issue`/`remove-issue`, `labels list`, `users list`, `states list`, `milestone list`/`view`/`create`/`update`/`delete` | off | Identifiers only, one per line (comment id for `issue comment`, relation id for `issue link`, **bare UUIDs** for the enumeration commands) |
| `--data-only` | same commands as `--quiet`, plus `gql` | off | Tab-separated rows; with `--json`, bare JSON instead of the wrapped envelope |
| `--plain` | `issues list`, `issue comment list`, `projects list`, `teams list`, `labels list`, `users list`, `states list`, `milestone list` | off | No cell padding or truncation |
| `--no-truncate` | same commands as `--plain` | off | Same effect as `--plain` in this CLI |
| `--limit N` | `issues list` (25), `projects list` (50), `search` (25), `issue comment list` (50), `labels list` (50), `users list` (50), `states list` (50), `milestone list` (50) | see left | Page size **per request** (max results for `search`/`issue comment list`, which do not paginate) |
| `--max-items N` | `issues list`, `projects list`, `labels list`, `users list`, `states list`, `milestone list` | unset | Hard stop after N items across all pages (may truncate mid-page) |
| `--pages N` | `issues list`, `projects list`, `labels list`, `users list`, `states list`, `milestone list` | 1 | Fetch up to N pages |
| `--cursor CURSOR` | `issues list`, `projects list`, `labels list`, `users list`, `states list`, `milestone list` | unset | Resume pagination after a cursor |
| `--sub-limit N` | `issues list`, `issue view` | 10 | Sub-issues per parent; **`0` disables the sub-query** |
| `--comment-limit N` | `issue view` | 10 | Comments to fetch; `0` disables |
| `--issue-limit N` | `project view` | 10 | Issues to fetch; `0` disables |
| `--human-time` | `issues list`, `issue view` | off | `3d ago` instead of a full ISO timestamp |

Flags that **add** output — only pass them when you need the extra data:

| Flag | Available on | Effect |
|------|--------------|--------|
| `--include-projects` | `issues list` | Adds `project` and `milestone` columns and their sub-queries |
| `--all` | `issues list`, `projects list`, `labels list`, `users list`, `states list`, `milestone list` | Fetches every page until exhausted (conflicts with `--pages`) |
| `--attachment-dir DIR` | `issue view` | Downloads `uploads.linear.app` files from the description into DIR (created 0600). Off unless the flag is passed; `--attachment-dir ""` is the same as omitting it |

### You need X → use Y, not Z

| You need | Use | Not |
|----------|-----|-----|
| Just the ticket IDs | `linear issues list --quiet` | `linear issues list --json` |
| ID + title only | `linear issues list --fields identifier,title --sub-limit 0 --plain` | `linear issues list` |
| A machine-readable list | `linear issues list --data-only --json --sub-limit 0` | `linear issues list --json` (wraps in `issues`/`pageInfo`/`limit`/`sort` envelope) |
| One issue's status | `linear issue view ENG-123 --fields identifier,state --data-only` | `linear issue view ENG-123` (prints everything) |
| A UUID from an identifier | `linear issue view ENG-123 --json \| jq -r .issue.id` | `--fields ... --json` (the flat projection has no `id` key) |
| Only 5 results | `linear issues list --limit 5 --sub-limit 0` | `linear issues list \| head -5` (the fetch already happened) |
| To scan many issues cheaply | `--fields identifier,title --max-items 100 --all --sub-limit 0` | `--all` alone |
| Team UUIDs | `linear teams list --fields id,key` | `linear teams list --json` |
| Label / user / state / milestone UUIDs | `linear labels list --team KEY --quiet` (etc. — see below) | a `gql` query, or `--json` and then `jq` |
| A name→id mapping for those | `linear states list --team KEY --fields id,name --data-only --limit 50` | `--json` |
| Comment bodies you intend to parse | `linear issue comment list --limit 20 --json` | `--data-only` (newlines are folded to spaces) |
| The identifier of the issue you are on | `linear issue id` (no request, no API key) | `git branch --show-current \| sed ...` |

### Field vocabularies (exact, per command)

- `issues list --fields`: `identifier`, `title`, `state`, `assignee`, `priority`, `updated`, `parent`,
  `sub_issues`, `project`, `milestone`. Default: `identifier,title,state,assignee,priority,updated`.
- `issue view --fields`: `identifier`, `title`, `state`, `assignee`, `priority`, `url`, `created_at`,
  `updated_at`, `description`, `project`, `milestone`, `parent`, `sub_issues`, `comments`.
  Default: everything except `project`, `milestone`, `parent`, `sub_issues`, `comments`.
- `project view --fields`: `id`, `name`, `slug`, `description`, `state`, `start_date`, `target_date`,
  `url`, `lead`, `teams`, `issues`.
- `projects list --fields`: `id`, `name`, `slug`, `description`, `state`, `start_date`, `target_date`, `url`.
- `teams list --fields`: `id`, `key`, `name`.
- `labels list --fields`: `id`, `name`, `color`, `description`, `team`. Default: `id,name,color,team`.
- `users list --fields`: `id`, `name`, `display_name`, `email`, `active`. Default: `id,name,display_name,email`.
- `states list --fields`: `id`, `name`, `type`, `position`, `team`. Default: all five.
- `milestone list --fields`: `id`, `name`, `target_date`, `sort_order`, `description`, `project`.
  Default: `id,name,target_date,sort_order,project`. `project` is a default because an unfiltered
  listing spans projects and milestone names repeat; drop it with `--fields` if you do not want it.
  Default: `id,name,target_date,sort_order`.
- `issue comment list --fields`: `id`, `author`, `body`, `created_at`, `updated_at`, `parent`, `url`.
  Default: `id,author,created_at,body`.
- `gql --fields`: arbitrary **top-level keys of the response `data` object** — not a fixed vocabulary.

An unknown field name is an error, not a silent skip (`issues list: invalid --fields value`).

## Traps

Each of these has a plausible-looking wrong command. The wrong one is named on purpose.

### `--fields` means two different things

- `linear issues list --fields ...` and `linear issue view --fields ...` select which fields to **print**.
- `linear search --fields ...` selects which fields to **search** — valid values are only
  `title`, `description`, `comments` (default `title,description`).

**Wrong:** `linear search "auth" --fields identifier,title` → `search: invalid --fields value`.
**Right:** `linear search "auth" --fields title,comments` (searches titles and comment bodies).

### `search` cannot be made compact

`search` has no `--fields`-for-output, no `--plain`, no `--no-truncate`, no `--quiet`, no `--data-only`.
It always prints the default six columns.

**Wrong:** `linear search "auth" --plain` → `search: unknown flag` + usage, exit 1. It does not ignore the
flag; it refuses to run.
**Right:** `linear search "auth" --limit 5`, or use `linear issues list` when you need a projection.

### `--state` is a state *type* on `issues list`, a state *name* on `issue update`

- `linear issues list --state` is an **alias of `--state-type`**. Values: `triage`, `backlog`,
  `unstarted`, `started`, `completed`, `canceled` (aliases: `todo` → `unstarted`,
  `in_progress`/`in-progress`/`inprogress` → `started`). It never matches a state's display name.
- `linear issue update --state` takes a workflow state **name** (case-insensitive) or a state id.

**Wrong:** `linear issues list --state "In Review"` → filters on a nonexistent state type, returns nothing useful.
**Right:** `linear issues list --state-id <STATE_UUID>` for one specific state, or `--state-type started`
for the category. Get state ids via the `gql` recipe below.

**Wrong:** `linear issue update ENG-123 --state started --yes` (that is a type, not a name).
**Right:** `linear issue update ENG-123 --state "In Review" --yes`. If the name is wrong, the CLI lists the
valid ones: `issue update: state 'X' not found; available states: Todo, In Progress, Done`.

### `issue delete` archives; use `--dry-run` first

`linear issue delete` calls the `issueDelete` mutation, which moves the issue to Linear's trash rather than
hard-deleting it. `--dry-run` resolves and validates the target, prints it, and exits 0 without mutating.

**Wrong:** assuming the issue is unrecoverable, or skipping straight to `--yes`.
**Right:** `linear issue delete ENG-123 --dry-run`, then `linear issue delete ENG-123 --yes`.

There is **no `--reason`**. Linear's `issueDelete` accepts `(id, permanentlyDelete)` and nothing else, so
a reason has nowhere to go — the flag used to be parsed and echoed back into this command's own output,
which read exactly like an audit trail that existed in Linear's trash or activity feed. It was removed
rather than deprecated, so it now fails during flag parsing:

```
issue delete: UnknownFlag
```

**Wrong:** `linear issue delete ENG-123 --reason "duplicate" --yes` — the flag is rejected, and it never
recorded anything in Linear when it was accepted.
**Right:** record the reason on your side —
`echo "ENG-123 duplicate" >> audit.log && linear issue delete ENG-123 --yes --json >> audit.jsonl`,
or leave it as a comment on the issue with `linear issue comment ENG-123 --body "duplicate" --yes`
before deleting, which *is* stored in Linear.

### Mutations without `--yes` fail on stderr — which piped stdout hides

Every mutating command (`issue create|update|delete|link|comment`, `project create|update|delete|add-issue|remove-issue`)
refuses without `--yes` (alias `--force`), printing to **stderr** and exiting 1:

```
issue update: confirmation required; re-run with --yes to proceed
```

**Wrong:** `linear issue update ENG-123 --assignee me | jq .` — stdout is empty, the error is invisible,
and it reads as a silent no-op.
**Right:** always pass `--yes`, and check the exit code rather than the piped output.

### `gql` is gated too — any `mutation` document needs `--yes`

`gql` scans the document for a top-level `mutation` operation (comments and string literals are skipped,
and a `mutation` field name nested inside a selection set does not count). If it finds one, the same
refusal applies:

```
gql: confirmation required; re-run with --yes to proceed
```

`--dry-run` reports what would be sent and exits 0 **without making a request** — it satisfies the gate on
its own, so `--yes` is not needed alongside it.

**Wrong:** `linear gql 'mutation { issueDelete(id: "abc") { success } }'` — nothing is sent, exit 1.
**Right:** `linear gql 'mutation { issueDelete(id: "abc") { success } }' --dry-run` to check it, then the
same command with `--yes`. Queries are unaffected — never add `--yes` to a read-only document.

### Never print the API key — `auth status` answers the question instead

`linear auth status` reports **which backend supplied the key and whether it is well-formed**, and the key
reaches no stream at all — not stdout, not stderr, not the `--json` document, not even as a redacted
fingerprint. It is the diagnostic to reach for, and the one that is safe to paste into a bug report:

```
source           : credential_helper
key              : present (format-valid, unverified)
verify           : run 'linear auth test' to check the key against the API
credential_helper: op read op://Private/Linear/api-key
keychain         : /usr/bin/security
file_api_key     : absent
config_path      : /Users/you/.config/linear/config.json
```

`format-valid` means **only** that the key matches the expected charset and length (4-512 characters from
`[A-Za-z0-9_-]`). `auth status` never touches the network, so a revoked key, a key for the wrong
workspace, or a fixture string like `test-key` all report `format-valid` and still fail on first use.
`linear auth test` is the only command that round-trips the credential against the API. A key that fails
even the charset check reports `present (malformed)`.

It exits **0 only when a well-formed key was found**, `1` otherwise, so it doubles as a *precondition*
check — not a proof that the key works.
`--json` reports the same facts as `source`, `key_present`, `key_format_valid`, `key_verified` (always
`null`, because status never verifies), `credential_helper`, `keychain_supported`, `file_key_present`,
`config_path` — and no `api_key` field exists in that object. (The old `key_valid` key was renamed to
`key_format_valid`; it always meant the format check.)

`linear auth show` is redacted (`lin_...abcd` — first four and last four characters) by default, including
with `--json`; a key shorter than 16 characters prints as `<redacted>`. `--reveal` prints the
real key and is refused unless stdout is a terminal, so in an agent session it fails rather than leaking:

```
auth show: refusing to reveal the API key because stdout is not a terminal
```

**Wrong:** `linear auth show --reveal`, or any command that echoes `$LINEAR_API_KEY` — a captured
credential ends up in transcripts and logs. Do not run these.
**Right:** `linear auth status` for where the key comes from, `linear auth test` for whether it works.
`--redacted` still parses on `auth show`, but it is a no-op alias — redaction is the default.

### `credential_helper` is an argv array, not a shell command line

`credential_helper` holds an external command whose **stdout** is the API key. No shell is ever spawned,
so quotes, pipes, `;`, `&&`, `$VAR`, and globs are ordinary bytes inside an argument — never syntax.

```jsonc
{ "credential_helper": ["op", "read", "op://Private/Linear/api-key"] }
```

A bare string (`"credential_helper": "pass show linear/api-key"`) is accepted and split on ASCII
whitespace with the same no-shell rule. There is no quoting: an argument that contains a space has to
use the array form.

**Wrong:** `"credential_helper": "op read op://$VAULT/Linear/api-key | head -1"` — `|`, `head`, and `-1`
become extra argv elements handed to `op`, and `$VAULT` stays literal — nothing expands it.
Any pipeline, redirect, or variable belongs in a script file that the helper *invokes*, not in the value.
**Right:** the array form above, or a wrapper: `["/usr/local/bin/linear-key.sh"]`.

Bounds, all enforced before the key can reach an `Authorization` header:

| Bound | Value |
|-------|-------|
| argv elements | at most **16** |
| bytes per element | at most **1024** (empty elements rejected) |
| helper timeout | **60 s** (generous on purpose — `op read` may wait on Touch ID) |
| output read cap | **4096 bytes**; the key itself must be **4-512** characters from `[A-Za-z0-9_-]` |

Trailing whitespace and the newline every secret manager emits are trimmed. The helper's **stdout is
never logged, printed, or quoted in a diagnostic** — that is where the secret is; only its exit status and
the first line of its stderr (200 bytes, control bytes stripped) appear.

Set it from the CLI with `config set`, which takes the same whitespace-split bare string:

```bash
linear config set credential_helper "op read op://Private/Linear/api-key"
```

This is the **bootstrap path that never puts the key on disk**: put the key in your secret manager, point
a helper at it, done. The helper is **run once before it is stored** and has to hand back a usable key.
One that fails to spawn, exits non-zero, prints nothing, or prints something that is not a key is refused
and nothing is written — a stored-but-broken helper *clears* the effective key instead of falling through
(see below), so saving one would lock you out. The argv bounds above are checked before anything is
spawned. Nothing the helper writes to stdout is ever printed.

```
config set: credential_helper 'op read op://Private/Linear/api-key' exited 1: vault is locked
config set: credential_helper was not saved
```

If a plaintext key is already on disk, there is nothing to migrate — set the helper up as above, then
delete `~/.config/linear/config.json` and rotate the old key. See
[Getting off a plaintext key](#getting-off-a-plaintext-key).

### A failing `credential_helper` clears the key — it does not fall through

A configured helper that fails does **not** degrade to the keychain or the plaintext config file. That
would silently reinstate the key the helper was configured to replace, so the chain stops, the failure is
reported on stderr, and the effective key is cleared. The key already on disk survives untouched, so
`auth status` still reports it as present.

The consequence, and the escape hatch:

- Every API command fails with `<cmd>: missing API key; run 'linear auth status' to see which backend is
  configured`, followed by the line naming the ways to set one up.
- `linear auth status` still runs and names the state (`source: credential_helper (failed)`, exit 1).
- `linear config unset credential_helper` still runs — neither needs a key.

**Wrong:** re-running the failing command with `--retries`, or assuming the config file key will cover it.
**Right:** `linear auth status` to confirm the state, fix the helper, or
`linear config unset credential_helper` to drop back to the next backend.

### Getting off a plaintext key

**There is no `auth migrate`.** Do not look for one, and do not try to reconstruct it. A key that reached
`~/.config/linear/config.json` has been on disk in cleartext, and nothing the CLI can do walks that back:
overwriting the bytes does not beat APFS copy-on-write, snapshots, Time Machine, or a synced folder that
already captured the file. The key has to be **rotated in Linear** either way — and once it is being
replaced, moving the old one somewhere nicer buys nothing.

```bash
# 1. Put the key in a secret manager, and rotate the old one in Linear.

# 2. Delete the config file. default_team_id and team_cache live there too, so
#    those reset with it.
rm ~/.config/linear/config.json

# 3. Set up again from scratch.
linear config set credential_helper "op read op://<vault>/<item>/<field>"
#    macOS, no secret manager, instead of the helper:
#    op read "op://<vault>/<item>/<field>" | linear auth set --to keychain
linear config set default_team_id TEAM_KEY
linear auth status && linear auth test
```

**Delete before you configure, not after.** `credential_helper` is stored *in* `config.json`, so setting
it first and deleting the file afterwards throws the new helper away along with the old key. `--to
keychain` writes nothing to the config file, but the order above is correct for both.

The per-run warning names the same steps:

```
warning: API key read from /Users/you/.config/linear/config.json; the config file stores it in plaintext.
warning: delete /Users/you/.config/linear/config.json to clear it (it also holds default_team_id and team_cache), then set up a backend that keeps the key off disk: 'linear config set credential_helper "op read op://<vault>/<item>/<field>"' (preferred) or 'linear auth set --to keychain'. Rotate the old key in Linear either way.
```

### UUID-only flags now have enumerating commands — do not reach for `gql`

Every id-taking filter has a dedicated `list` command. `--quiet` prints bare ids, one per line, which is
the cheapest form and the one to substitute into another command.

| Flag | Command | Enumerate with |
|------|---------|----------------|
| `--assignee` (someone other than `me`) | `issues list`, `search`, `issue create`, `issue update` | `linear users list --limit 50 --quiet` |
| `--label` / `--labels` | `issues list` (`--label`), `issue create` (`--labels`) | `linear labels list --team KEY --limit 50 --quiet` |
| `--state-id` | `issues list` | `linear states list --team KEY --limit 50 --quiet` |
| `--milestone` | `issues list` | `linear milestone list [--project ID\|NAME] --limit 50 --quiet` |

```bash
linear labels list --team ENG --limit 50 --fields id,name --data-only
linear users list --limit 50 --fields id,email --data-only
linear states list --team ENG --limit 50 --fields id,name,type --data-only
linear milestone list --project "Roadmap" --limit 50 --fields id,name --data-only
linear milestone list --limit 50 --fields id,name,project --data-only   # every project
```

**Wrong:** `linear gql --data-only 'query { issueLabels(first: 100) { nodes { id name } } }'` — a raw
query where a projection-capable command exists.
**Right:** `linear labels list --team ENG --limit 50 --fields id,name --data-only`.

There is no remaining enumeration gap: `milestone list` with no `--project` lists every project's
milestones (the `Project` column disambiguates them), and all five enumeration commands walk cursors
with `--pages N` / `--all` / `--cursor` / `--max-items`, so neither a cross-project listing nor a
long one needs `gql`.

`--assignee me` is resolved by the CLI on `issues list`, `search`, and `issue update` — prefer it.
`--project` and `--team` also need no lookup: `linear projects list --fields id,name` and
`linear teams list --fields id,key` enumerate them, `--team` accepts a team key, and `--project` on
`milestone list|create` accepts a project id, slug, or exact name.

### `milestone list --project NAME` fails on a duplicate name

A non-UUID `--project` is matched against `slugId` **or** exact `name`. Two matches is an error, not a
first-wins pick:

```
milestone list: project 'Roadmap' is ambiguous; pass the project id
milestone list: project 'Roadmap' not found
```

**Wrong:** `linear milestone list --project roadmap` — the name match is exact, not case-insensitive and
not a substring.
**Right:** `linear projects list --fields id,name --limit 50`, then pass the id.

The same resolution applies to `milestone create --project`.

### Comment bodies are folded to one line unless you ask for JSON

`issue comment list` replaces every `\r`, `\n`, and `\t` inside a body with a space for the table and for
tab-separated `--data-only` output — a multi-line markdown comment becomes one row either way. `--json`
returns the body verbatim, including under `--data-only --json`.

**Wrong:** `linear issue comment list ENG-123 --fields body --data-only` when you intend to read or
re-post the body — the newlines are gone and cannot be recovered.
**Right:** `linear issue comment list ENG-123 --limit 20 --json`, or
`--fields id,body --data-only --json`.

### Inline and file flags are mutually exclusive — the pair errors, it does not pick one

`--description`/`--description-file` (`issue create`, `issue update`, `milestone create`,
`milestone update`), `--body`/`--body-file` (`issue comment`, `issue comment update`), and
`--content`/`--content-file` (`project create`, `project update`) each refuse both at once:

```
issue create: cannot use both --description and --description-file
```

Every `--*-file` flag takes `-` to mean stdin, and every one caps the content at **1048576 bytes**
(1 MiB):

```
issue create: file 'body.md' exceeds the 1048576 byte limit
issue create: stdin exceeds the 1048576 byte limit
issue create: cannot read file 'body.md': FileNotFound
```

**Wrong:** `linear issue create --team ENG --title T --description "" --description-file body.md --yes`
expecting the file to win — the command exits 1 and creates nothing.
**Right:** pick one form. `cat body.md | linear issue create --team ENG --title T --description-file - --yes`.

### `gql --paginate` validates the document before it sends anything

`--paginate` re-issues the query with each returned `endCursor` and merges the connection's `nodes`
arrays. Three conditions are checked **up front**, before the first request and before an API key is
even required, so a query that cannot be walked fails immediately rather than silently returning page one:

```
gql: --paginate cannot be used with a mutation document
gql: --paginate requires the query to declare an $after variable
gql: --paginate requires the query to select pageInfo { hasNextPage endCursor }
```

The query must declare `$after`, pass it to the connection, and select
`pageInfo { hasNextPage endCursor }`. The **shallowest** connection in the response (breadth-first, object
children only) is the one walked. `--max-pages` defaults to **20**; hitting it is reported on stderr and
is not an error:

```
gql: --paginate stopped after 20 pages (--max-pages 20); more results remain
```

**Wrong:** `linear gql 'query { issues(first: 50) { nodes { id } } }' --paginate` → rejected, exit 1.
**Right:**

```bash
linear gql --paginate --max-pages 5 --data-only '
query Issues($after: String) {
  issues(first: 50, after: $after) {
    nodes { identifier title }
    pageInfo { hasNextPage endCursor }
  }
}'
```

### Bulk deletes do not abort on failure — check the exit code

`--bulk ID,ID`, `--bulk-file PATH`, and `--bulk-stdin` on `issue delete` and `milestone delete` run
**serially**, deduplicate ids keeping first-seen order, and cap the batch at **500**. A failed item is
counted and the run continues; the exit code is non-zero if any item failed, and the summary goes to
**stderr** (suppressed under `--json`):

```
issue delete: bulk complete; 3 succeeded, 1 failed
issue delete: use only one of --bulk, --bulk-file, or --bulk-stdin
issue delete: bulk input contained no ids
issue delete: bulk input has 900 ids; the limit is 500
issue delete: pass an identifier or --bulk, not both
```

Input is split on commas and ASCII whitespace, so a newline-delimited file and `--bulk a,b` both work.
`--dry-run` applies per item and needs no `--yes`.

**Wrong:** `linear issue delete --bulk ENG-1,ENG-2 --yes | jq .` and treating empty output as success.
**Right:** run it, then check `$?`; under `--json` the bulk path streams a JSON array to stdout.

## Discovering Options

Every command's usage block ends with an `Examples:` section, and `linear help <command>` routes to it.
Run it before guessing a flag — it is cheaper than a failed call plus a retry.

```bash
linear help issues        # issues list: all filters, pagination, projection flags
linear help issue view
linear help issue update
linear help issue comment list
linear help issue start
linear help issue describe
linear help labels        # also: users, states
linear help milestone     # prints list/view/create/update/delete usage in one block
linear help search
linear help gql
linear help project create
```

`linear help` with no argument lists every command. `--help` on a command does the same thing.
(The two exceptions with no `Examples:` block are `linear help config` and `linear help config show`.)

## Install & Setup
- Install: `npm install -g @0xbigboss/linear-cli`
- Auth resolves through a fixed chain, highest precedence first — run `linear auth status` to see which
  one is actually supplying the key:

  ```
  LINEAR_API_KEY  ->  credential_helper  ->  keychain (macOS)  ->  config file (deprecated, warns)
  ```

- **1Password and other secret managers: use `credential_helper`.** It is the portable backend (every
  platform) and the key is never written to disk:

  ```bash
  # 1. Put the key in the manager. 2. Point a helper at it. Nothing touches disk.
  linear config set credential_helper "op read op://<vault>/<item>/<field>"
  linear auth status        # source: credential_helper
  linear auth test          # and it actually works
  ```

  `config set` runs the helper before storing it and refuses to save one that does not return a usable
  key, so a broken helper can never be persisted. See
  [Traps](#credential_helper-is-an-argv-array-not-a-shell-command-line) for the argv rule and the bounds.

  A plaintext key already in the config file is **not** something to move. See
  [Getting off a plaintext key](#getting-off-a-plaintext-key).
- **macOS with no secret manager:** `op read ... | linear auth set --to keychain` (item
  `linear-cli`/`api-key`, written and read via `/usr/bin/security`). The key reaches `security -i` on
  stdin, never in an argv, and the item is read back and compared before the command reports success.
  This buys **encryption at rest** and immunity to accidental disclosure — backups, synced folders, a
  stray `cat` of the config. It is **not** process isolation: the item is ACL'd to `/usr/bin/security`,
  so any process running as you can read it back non-interactively with no prompt. The backend does not
  exist on Linux or Windows; `--to keychain` fails there rather than quietly writing the plaintext file.
- **Ephemeral / CI:** `export LINEAR_API_KEY=...` — read on every run, outranks everything, never written
  to disk. Nothing to clean up.
- `linear auth set` with no `--to` (or `--to file`) writes the config file in plaintext and is
  **deprecated**: the file backend warns on every run that reads it. Reach for it only when neither a
  secret manager nor the keychain is available.
- There is no `--api-key` flag — keys are never accepted on argv, where any process on the machine could
  read them out of the process table
- Keys must be 4-512 characters from `[A-Za-z0-9_-]`; anything else is rejected at every ingestion point
  (config file, `LINEAR_CONFIG`, `LINEAR_API_KEY`, `auth set`, and every credential backend)
- Defaults: `linear config set default_team_id TEAM_KEY`, `linear config set default_output json|table`, `linear config set default_state_filter completed,canceled`
- `default_team_id` is verified against the workspace before it is written: an unknown team is refused
  (nothing saved), and a lookup that could not complete is reported as `could not verify team` rather than
  as a missing one. There is no `--force`
- Inspect or reset defaults: `linear config show`, `linear config unset default_output`
- Config path: `~/.config/linear/config.json` (override with `--config PATH` or `LINEAR_CONFIG`)

## Prerequisites
- CLI installed and on PATH
- Valid Linear API key available
- Team defaults set or provided per command (team key/UUID)

## Hygiene

- **Branches**: Name as `{TICKET}-{short-name}` (e.g., `ENG-123-fix-auth`); prefer git worktrees for
  parallel work. `linear issue start ENG-123 --yes` checks out Linear's own `branchName` (creating it if
  needed) and moves the issue into the team's first `started` state in one step
- **Commits**: Use conventional commits; ticket ID in body or trailer, not subject.
  `git commit -m "$(linear issue describe)"` emits the subject plus `Linear-issue:`/`Linear-issue-url:`
  trailers for the inferred issue
- **Assignment**: Assign yourself when starting work (`linear issue update ENG-123 --assignee me --yes`)
- **Sub-issues**: Set parent to associate related work (`linear issue update ENG-123 --parent ENG-100 --yes`;
  `--parent` accepts an identifier or an id)
- **Scope creep**: Create separate issues for discovered work; link with blocks relation (`linear issue link ENG-123 --blocks ENG-456 --yes`)
- **Cycles/projects**: Ask user preference when creating issues

## Quick Recipes

Every recipe below is bounded. Do not drop the limits.

### List my issues
```bash
linear issues list --team TEAM_KEY --assignee me --limit 20 --sub-limit 0 --human-time
```

### List just the identifiers
```bash
linear issues list --team TEAM_KEY --assignee me --limit 20 --sub-limit 0 --quiet
```

### Search issues
```bash
linear search "keyword" --team TEAM_KEY --limit 10
```

### What changed recently
```bash
# Strictly after the timestamp; newest first
linear issues list --team TEAM_KEY --updated-since 2026-07-01T00:00:00Z \
  --sort updated:desc --limit 20 --sub-limit 0 --human-time

# Issues opened this month, oldest first
linear issues list --team TEAM_KEY --created-since 2026-07-01T00:00:00Z \
  --sort created:asc --limit 20 --sub-limit 0 --quiet
```

### Create an issue
```bash
linear issue create --team TEAM_KEY --title "Fix bug" --yes --quiet
# --quiet prints just the identifier (e.g., ENG-123)
```

### Write long-form content from a file or stdin
```bash
# Issue description
linear issue create --team TEAM_KEY --title "Imported" --description-file body.md --yes --quiet
cat body.md | linear issue update ENG-123 --description-file - --yes --quiet

# Project content (--description is capped at 255 chars by Linear; --content is not)
linear project update PROJECT_ID --content-file overview.md --target-date 2026-12-31 --yes --quiet
```

Passing both the inline flag and its `-file` twin is an error, not a precedence rule, and the file/stdin
cap is 1 MiB. See [Traps](#inline-and-file-flags-are-mutually-exclusive--the-pair-errors-it-does-not-pick-one).

### View issue details
```bash
linear issue view ENG-123
```

### Download attachments from issues
```bash
# Download a specific file (requires LINEAR_API_KEY)
linear download "https://uploads.linear.app/..." --output screenshot.png

# issue view downloads description attachments only when you name a directory.
# Files land in DIR with mode 0600; each path is echoed on stderr.
linear issue view ENG-123 --attachment-dir ./attachments

# Default: no directory, no download. Nothing to disable.
linear issue view ENG-123
```

### Get issue as JSON for processing
```bash
linear issue view ENG-123 --json
```

### Get issue with full context (for agents/analysis)

The most expensive command in this file. Bound the sub-issue and comment counts explicitly.

```bash
linear issue view ENG-123 \
  --fields identifier,title,state,assignee,priority,url,description,parent,sub_issues,comments \
  --sub-limit 5 --comment-limit 10 --json
```

Cheaper first pass — skip `comments` and `sub_issues` entirely, then re-run for the ones that matter:

```bash
linear issue view ENG-123 --fields identifier,title,state,description --data-only
```

### List all teams
```bash
linear teams list --fields id,key,name
```

### Enumerate labels, users, workflow states, and milestones
```bash
linear labels list --team TEAM_KEY --limit 50 --fields id,name --data-only
linear users list --limit 50 --fields id,name,email --data-only
linear states list --team TEAM_KEY --limit 50 --fields id,name,type --data-only

# Milestones for one project, or workspace-wide when --project is omitted
linear milestone list --project "Roadmap" --limit 50 --fields id,name --data-only
linear milestone list --all --fields id,name,project --data-only

# Bare ids only — the cheapest form, one per line
linear labels list --team TEAM_KEY --limit 50 --quiet

# Past the first page: --all walks to the end, --pages N takes N pages,
# --cursor resumes from the value stderr printed, --max-items caps the total
linear users list --all --quiet
linear states list --pages 3 --limit 50 --fields id,name,team --data-only
linear labels list --team TEAM_KEY --all --max-items 200 --quiet

# Substitute straight into a filter
linear issues list --team TEAM_KEY --limit 20 --sub-limit 0 \
  --label "$(linear labels list --team TEAM_KEY --limit 1 --quiet)"
```

### Read an issue's comments
```bash
# Table (bodies folded to one line)
linear issue comment list ENG-123 --limit 20 --fields id,author,created_at

# Verbatim bodies for programmatic use — --json is required
linear issue comment list ENG-123 --limit 20 --json | jq -r '.issue.comments.nodes[].body'
```

### Edit or remove a comment
```bash
linear issue comment update COMMENT_ID --body "Corrected text" --yes --quiet
cat body.md | linear issue comment update COMMENT_ID --body-file - --yes --quiet
linear issue comment delete COMMENT_ID --yes --quiet
```

`update` and `delete` take a **comment** id (from `issue comment list --quiet`), not an issue
identifier, and neither infers anything from the branch.

### Manage milestones
```bash
linear milestone create --project "Roadmap" --name "Beta" --target-date 2026-09-30 --yes --quiet
linear milestone update MILESTONE_ID --target-date 2026-10-15 --yes --quiet
linear milestone view MILESTONE_ID --data-only
linear milestone delete MILESTONE_ID --dry-run
linear milestone delete MILESTONE_ID --yes --quiet
```

### Start work on an issue from a git repo
```bash
# Checks out Linear's branchName (creating it from --from-ref when new) and
# transitions the issue to the team's first 'started' state.
linear issue start ENG-123 --from-ref main --yes --quiet

# ...then a commit message with Linear trailers, and a PR
git commit -m "$(linear issue describe)"
linear issue pr --base main --draft --yes
```

`issue describe` emits exactly this, and nothing else:

```
ENG-123 Fix the auth redirect

Linear-issue: Fixes ENG-123
Linear-issue-url: https://linear.app/acme/issue/ENG-123/...
```

`--references` swaps `Fixes` for `References` when the commit should link without closing.

`issue pr` shells out to `gh pr create` with inherited stdio, so `gh`'s prompts still work and its
output is not capturable through this CLI. The PR title is `<IDENTIFIER> <title>` and the body is the
issue URL, which is what Linear's GitHub integration matches on. A non-zero `gh` status is propagated
(`issue pr: gh pr create exited with status N`).

### Delete several issues in one run
```bash
# Always dry-run the batch first — nothing is sent, and --yes is not needed
linear issues list --team TEAM_KEY --limit 25 --quiet | linear issue delete --bulk-stdin --dry-run

linear issue delete --bulk ENG-1,ENG-2 --yes --quiet
echo $?   # non-zero if ANY item failed; the summary is on stderr
```

### Page through a large GraphQL result
```bash
linear gql --paginate --max-pages 5 --data-only '
query TeamIssues($after: String) {
  issues(first: 50, after: $after) {
    nodes { identifier title }
    pageInfo { hasNextPage endCursor }
  }
}'
```

### Verify authentication
```bash
# Where is the key coming from? Never prints the key; exit 1 when there is no usable one.
linear auth status

# Does that key actually work? (one `viewer` request)
linear auth test
```

### List projects
```bash
linear projects list --limit 10 --fields id,name,state
```

### View or change CLI defaults
```bash
linear config show
linear config set default_output json
linear config unset default_state_filter

# default_team_id is verified against the workspace; an unknown team is refused
# and nothing is written.
linear config set default_team_id ENG

# config show also prints credential_helper (the argv, never the key it fetches).
# Setting it runs the helper first and refuses to save one that fails.
linear config set credential_helper "op read op://Private/Linear/api-key"
linear config unset credential_helper
```

### Add a comment to an issue
```bash
linear issue comment ENG-123 --body "Comment text here" --yes --quiet

# Or from a file/stdin
cat notes.md | linear issue comment ENG-123 --body-file - --yes --quiet

# Threaded reply to an existing comment
linear issue comment ENG-123 --body "Following up" --parent COMMENT_ID --yes --quiet

# Inside the issue's git branch, the identifier can be dropped entirely
linear issue comment --body "Comment text here" --yes --quiet
```

### Create and manage a project
```bash
# Create project (team UUID or key)
linear project create --team TEAM_UUID --name "My Project" --state planned --yes --quiet

# Update project state
linear project update PROJECT_ID --state started --yes --quiet

# Add issue to project
linear project add-issue PROJECT_ID ISSUE_UUID --yes --quiet
```

### View a project without pulling its issue list
```bash
linear project view PROJECT_ID --fields name,state,target_date --issue-limit 0
```

## Command Reference

Commands marked † infer the issue from the current git branch when the ID is omitted — see
[Branch Inference](#branch-inference--the-id-argument-is-usually-optional).

| Command | Purpose |
|---------|---------|
| `linear issues list` | List issues with filters |
| `linear search "keyword"` | Search issues by text |
| `linear issue view [ID]` † | View single issue |
| `linear issue create` | Create new issue (`--description` or `--description-file`) |
| `linear issue update [ID]` † | Update issue (assign, state, priority, parent, description) |
| `linear issue link [ID]` † | Link issues (blocks, related, duplicate) |
| `linear issue comment [ID]` † | Add comment to issue (`--parent COMMENT_ID` for a threaded reply) |
| `linear issue comment list [ID]` † | List an issue's comments |
| `linear issue comment update CID` | Replace a comment body (`--body` or `--body-file`) |
| `linear issue comment delete CID` | Delete a comment |
| `linear issue delete ID` | Archive an issue (supports `--dry-run`, `--bulk*`; there is no `--reason`) |
| `linear issue start [ID]` † | Check out the issue's git branch and move it to a `started` state |
| `linear issue pr [ID]` † | Run `gh pr create` with the issue title/URL |
| `linear issue id\|url\|title [ID]` † | Print one field on a single line (`issue id` makes no request) |
| `linear issue describe [ID]` † | Commit-message body with `Linear-issue` trailers |
| `linear projects list` | List projects |
| `linear project view ID` | View project details |
| `linear project create` | Create new project (`--content`/`--content-file`, `--start-date`, `--target-date`) |
| `linear project update ID` | Update project (state, name, content, dates) |
| `linear project delete ID` | Archive a project |
| `linear project add-issue` | Add issue to project |
| `linear project remove-issue` | Remove issue from project |
| `linear milestone list` | List milestones, workspace-wide or for one project (`--project ID\|NAME`, optional) |
| `linear milestone view ID` | View one milestone |
| `linear milestone create` | Create a milestone (`--project`, `--name` required) |
| `linear milestone update ID` | Update a milestone (name, description, target date, sort order) |
| `linear milestone delete ID` | Delete a milestone (supports `--dry-run`, `--bulk*`) |
| `linear teams list` | List available teams |
| `linear labels list` | List issue labels — ids for `issues list --label` / `issue create --labels` |
| `linear users list` | List users — ids for `--assignee` (`--include-inactive` adds deactivated members) |
| `linear states list` | List workflow states — ids for `issues list --state-id` |
| `linear auth status` | Report which backend supplies the key and whether it is well-formed (offline; never prints it) |
| `linear auth test` | Validate the current key against the API (`viewer`) |
| `linear auth show` | Print the configured key, redacted (`--reveal` needs a TTY) |
| `linear auth set --to keychain` | Store a key in the macOS keychain, read from stdin or a no-echo prompt |
| `linear auth set` | Store a key in the config file in plaintext — **deprecated**, prefer `config set credential_helper` |
| `linear me` | Show current user |
| `linear gql` | Run raw GraphQL (mutation documents need `--yes`; supports `--dry-run`, `--paginate`) |
| `linear download` | Download uploads.linear.app attachments |
| `linear help CMD` | Command-specific help and examples |

## Common Flags

Global flags, accepted before or after the subcommand:

- `--json` — JSON output (also settable via `config set default_output json`)
- `--config PATH` — alternate config file
- `--endpoint URL` — override the GraphQL endpoint. Allowlisted: the URL must use `https` and the host
  must be `api.linear.app`, otherwise the CLI exits 1 before any request (and before the `Authorization`
  header is built). `LINEAR_ALLOW_INSECURE_ENDPOINT=1` — and only the literal `1` — relaxes both checks
  for mock/QA servers; the URL still has to parse with a host. Leave the flag off for normal work.
- `--retries N` — retry count for 5xx (default: 0)
- `--timeout-ms MS` — request timeout (default: 10000)
- `--no-keepalive` — disable HTTP keep-alive
- `--help`, `--version`

Per-command flags worth knowing:

- `--team ID|KEY` — required for `issues list` unless `default_team_id` is configured; also filters
  `labels list` and `states list`
- `--updated-since TS` / `--created-since TS` — `issues list` only. Both map to a **strictly greater
  than** comparator on `updatedAt`/`createdAt`, so the boundary timestamp itself is excluded. The value
  is forwarded to Linear verbatim; pass an ISO 8601 timestamp
- `--sort FIELD[:asc|desc]` — `issues list` only. `FIELD` is `created` or `updated` (`createdAt`/`updatedAt`
  also accepted, case-insensitive); direction defaults to `desc`. Anything else is
  `issues list: invalid --sort value`
- `--yes` — required for every mutation, including a `mutation` document passed to `gql` (alias: `--force`).
  `issue comment update|delete`, `issue start`, `issue pr`, and `milestone create|update|delete` are
  gated the same way
- `--dry-run` — `issue delete`, `milestone delete`, and `gql`; validates/reports and exits 0 without
  mutating, and satisfies the `--yes` gate on its own
- `--bulk ID,ID` / `--bulk-file PATH` / `--bulk-stdin` — `issue delete` and `milestone delete` only
- `--*-file PATH` — `-` reads stdin; mutually exclusive with the inline twin; 1 MiB cap
- `--paginate` / `--max-pages N` — `gql` only (default 20 pages)
- See [Token Discipline](#token-discipline) for the output-shaping flags

## Workflow: Creating and Linking Issues

```
Progress:
- [ ] List teams to get TEAM_KEY: `linear teams list --fields id,key`
- [ ] Create parent issue: `linear issue create --team KEY --title "Epic" --yes --quiet`
- [ ] Create child issue: `linear issue create --team KEY --title "Task" --yes --quiet`
- [ ] Set parent: `linear issue update CHILD_ID --parent PARENT_ID --yes --quiet`
- [ ] Create another issue to link: `linear issue create --team KEY --title "Blocked" --yes --quiet`
- [ ] Link blocking issue: `linear issue link ISSUE_ID --blocks OTHER_ID --yes --quiet`
- [ ] Verify: `linear issue view ISSUE_ID --fields identifier,parent,sub_issues --data-only`
```

## Errors → Fixes

Keyed on the exact stderr text the CLI emits. **All of these go to stderr**, including the pagination and
truncation notices — a command piped as `linear ... | jq` shows none of them. Check the exit code, and do
not redirect stderr away.

| stderr message | Fix |
|----------------|-----|
| `<cmd>: confirmation required; re-run with --yes to proceed` | Add `--yes` (or `--force`) |
| `<cmd>: missing API key; run 'linear auth status' to see which backend is configured` (plus the follow-up line naming `config set credential_helper`, `auth set --to keychain`, and `LINEAR_API_KEY`) | Run `linear auth status` first — with a broken `credential_helper` the chain clears the key rather than falling through, and this is what every API command then says |
| `<cmd>: unauthorized (key lin_...); run 'linear auth status' to see which backend supplied it` (plus the follow-up `then replace it: ...` line) | Key is invalid/revoked; `linear auth status` for which backend produced it, `linear auth test` to re-check |
| `auth set: invalid API key; expected 4-512 characters from [A-Za-z0-9_-]` | The piped/typed key has stray bytes (a trailing `\r`, a wrapped line, a quote). Re-pipe the bare key; nothing was written to disk |
| `failed to load config: api key must be 4-512 characters from [A-Za-z0-9_-]` | Same charset rule, applied to the key already in the config file or `LINEAR_API_KEY`. Fix the value, or delete the config file and set the key up again |
| `auth set: no API key supplied; pipe one on stdin or run interactively (LINEAR_API_KEY is never written to disk)` | stdin was empty and there is no TTY to prompt on. Pipe the key in; `auth set` will not persist an environment key |
| `auth show: refusing to reveal the API key because stdout is not a terminal` | Drop `--reveal` — do not work around this. `linear auth status` says where the key comes from, `linear auth test` says whether it works |
| `warning: API key read from PATH; the config file stores it in plaintext.` + `warning: delete PATH to clear it (it also holds default_team_id and team_cache), then set up a backend that keeps the key off disk: 'linear config set credential_helper "..."' (preferred) or 'linear auth set --to keychain'. Rotate the old key in Linear either way.` | Not an error — the deprecated file backend supplied the key, and says so on every run. Follow the steps in [Getting off a plaintext key](#getting-off-a-plaintext-key); the old key has been on disk, so treat it as disclosed and rotate it |
| `linear: credential_helper 'CMD' was not found on PATH` | Helper binary missing. Nothing falls through while it is broken — fix it, or `linear config unset credential_helper` |
| `linear: credential_helper 'CMD' could not be started` | Spawn refused (not executable, bad interpreter). Same escape hatch |
| `linear: credential_helper 'CMD' did not finish in time` | Killed at the 60 s budget — usually a helper blocked on a prompt nobody answered |
| `linear: credential_helper 'CMD' exited N: <first line of its stderr>` | The helper itself failed (locked vault, wrong item path). Run it by hand; the CLI never quotes its stdout, only stderr |
| `linear: credential_helper 'CMD' produced no output` | Exit 0 with empty stdout is a failure, not an empty store — check the item path |
| `linear: credential_helper 'CMD' produced more than 512 characters, which cannot be an API key` | The helper is printing a banner or a JSON blob; it must print the bare key |
| `linear: credential_helper 'CMD' produced something that is not a valid API key; expected 4-512 characters from [A-Za-z0-9_-]` | Stray quotes, a `\r`, or a whole payload on stdout — print the bare key |
| `linear: /usr/bin/security ...` (the same failure texts, minus `exited N`) | The keychain probe failed. Unlike a helper this is **not** fatal: the chain still falls through to the config file. A non-zero exit from the read means "no such item" and is silent by design |
| `failed to resolve credentials: api key must be 4-512 characters from [A-Za-z0-9_-]` | Last-resort check on a backend-supplied key (each backend already validates its own output, so this should not normally fire) |
| `failed to load config: credential_helper must name a command` / `... has too many arguments` / `... arguments must be non-empty and shorter than 1024 bytes` / `... must be an array of strings` | The `credential_helper` value is empty, has more than 16 elements, has an element that is empty or over 1024 bytes, or is not an array of strings (or a bare string) |
| `config set: credential_helper was not saved` (preceded by the helper's own failure line) | `config set` runs the helper before storing it; a helper that fails, prints nothing, or prints a non-key is refused, because a stored-but-broken one clears the key rather than falling through |
| `config set: team 'X' not found in workspace; default_team_id was not changed` | The lookup succeeded and the workspace has no such team — check `linear teams list --fields id,key`. Nothing was written |
| `config set: could not verify team 'X'; default_team_id was not changed` | The lookup itself did not complete (timeout, 5xx, offline) — this is not a verdict on the team. Nothing was written; retry, or pass `--team` per command |
| `auth: unknown command: migrate` | `auth migrate` was removed. Follow [Getting off a plaintext key](#getting-off-a-plaintext-key): set up a helper or the keychain, delete the config file, rotate the key |
| `auth set: UnknownBackend` | `--to` takes `keychain` or `file`, nothing else. There is no `--to helper` — use `linear config set credential_helper "<command>"` |
| `auth set: the keychain backend is only available on macOS; use 'linear config set credential_helper "<command>"' instead` | `--to keychain` refuses on Linux/Windows rather than silently writing the plaintext file |
| `auth set: the keychain item could not be read back after writing it; nothing was stored` (also `... read back a different key than was written; ...`) | The write reported success but the item is not there or holds something else. `security -i` reports on the session, not on each command, so the read-back is what decides |
| `auth set: this API key starts with '-', which /usr/bin/security would read as an option; put it in a secret manager and use 'linear config set credential_helper "<command>"' instead` | The keychain write refuses rather than working around `security`'s tokenizer |
| `auth set: process execution is unavailable` | `--to keychain` needs to spawn `/usr/bin/security`; it will not fall back to the file |
| `<cmd>: HTTP status 429` + `<cmd>: rate limit: remaining 0/1500; reset in ~NNNNms` | Wait for the printed reset window |
| `<cmd>: request timed out after 10000ms` | Raise `--timeout-ms`, add `--retries 2`, or lower `--limit` |
| `linear: --endpoint rejected: endpoint must use https; set LINEAR_ALLOW_INSECURE_ENDPOINT=1 to allow other schemes` | Use an `https` URL; the env var is for mock/QA servers only |
| `linear: --endpoint rejected: endpoint host must be api.linear.app; set LINEAR_ALLOW_INSECURE_ENDPOINT=1 to allow other hosts` | Only `api.linear.app` is allowlisted — drop `--endpoint` unless you are pointed at a mock |
| `linear: --endpoint rejected: endpoint must be an absolute URL with a host` | The value did not parse as a URL with a host (this one is enforced even under `LINEAR_ALLOW_INSECURE_ENDPOINT=1`) |
| `issues list: missing team selection` | Pass `--team KEY` or set `default_team_id` |
| `issues list: team 'X' not found` | Wrong key/UUID — check `linear teams list --fields id,key` |
| `issues list: unknown flag` / `search: unknown flag` | Flag does not exist on that command — run `linear help <cmd>` |
| `issues list: invalid --fields value` | Field name not in that command's vocabulary (see above) |
| `issues list: no fields selected` | `--fields` resolved to an empty set |
| `issues list: invalid --max-items value` | `--max-items 0` is rejected; omit the flag instead |
| `issues list: invalid --sort value` | `--sort` takes `created\|updated` optionally suffixed `:asc`/`:desc` — nothing else |
| `issue delete: UnknownFlag` on `--reason` | `--reason` was removed — `issueDelete` has no reason parameter, so it never reached Linear. Record it on your side, or leave a comment on the issue before deleting |
| `issues list: fetched N items across M pages; more available, resume with --cursor XXX` | Not an error — pass `--cursor XXX`, or `--pages N` / `--all` |
| `issues list: stopped after N items due to --max-items` | Not an error — raise `--max-items` if you need more |
| `issues list: sub-issues limited to 10; additional sub-issues omitted` | Raise `--sub-limit`, or set `--sub-limit 0` if you never wanted them |
| `issue view: comments limited to 10; additional comments omitted` | Raise `--comment-limit` |
| `project view: issues limited to 10; additional issues omitted` | Raise `--issue-limit` |
| `search: additional results available; pagination not implemented (resume with cursor XXX)` | `search` cannot paginate — narrow the query or use `issues list --cursor` |
| `search: 0 results (team filter: XXX)` | The team filter excluded everything; retry without `--team` |
| `issue view: issue not found` / `<cmd>: issue 'X' not found` | Wrong identifier or no access |
| `<cmd>: invalid issue identifier; expected TEAM-NUMBER` | Use `ENG-123` form or a UUID |
| `issue update: state 'X' not found; available states: A, B, C` | Use one of the listed names verbatim |
| `issue update: at least one field to update is required` | Supply at least one of `--assignee/--parent/--state/--priority/--title/--description/--description-file/--project` |
| `<cmd>: branch 'X' has no issue identifier; pass one explicitly` | The branch is not named `TEAM-123-...` — pass the identifier |
| `<cmd>: HEAD is detached; pass an issue identifier explicitly` | Check out a branch, or pass the identifier |
| `<cmd>: not a git repository; pass an issue identifier explicitly` | Run from inside the repo, or pass the identifier |
| `<cmd>: git was not found on PATH; pass an issue identifier explicitly` | Install `git`, or pass the identifier |
| `<cmd>: cannot use both --X and --X-file` | Pick the inline flag or the file flag, never both |
| `<cmd>: file 'P' exceeds the 1048576 byte limit` / `<cmd>: stdin exceeds the 1048576 byte limit` | Content flags cap at 1 MiB — trim the input |
| `<cmd>: cannot read file 'P': <ErrorName>` | Bad path/permissions on a `--*-file` value |
| `labels list: --limit must be greater than zero` (same for `users`/`states`/`milestone list`/`issue comment list`) | `--limit 0` is rejected; omit the flag for the default of 50 |
| `labels list: invalid --team value` / `states list: invalid --team value` | `--team` was empty/whitespace |
| `labels list: fetched N items across M pages; more available, resume with --cursor X` (same shape for `users`/`states`/`projects list`/`milestone list`) | Not an error — pass `--cursor X`, or `--pages N` / `--all` |
| `labels list: stopped after N items due to --max-items` (same shape for the other list commands) | Not an error — raise `--max-items` if you need more |
| `issue comment list: more comments available; pagination not implemented (endCursor X)` | `issue comment list` does not paginate — raise `--limit` |
| `<cmd>: ConflictingPageFlags` | `--all` and `--pages` are mutually exclusive; pass one |
| `milestone list: project 'X' is ambiguous; pass the project id` | Two projects share the slug/name — use the id from `projects list` |
| `milestone update: provide at least one of --name, --description, --description-file, --target-date, or --sort-order` | Supply a field flag |
| `milestone create: --project is required` / `milestone create: --name is required` | Both are mandatory |
| `<cmd>: use only one of --bulk, --bulk-file, or --bulk-stdin` | Pick one bulk source |
| `<cmd>: bulk input contained no ids` | The file/stdin/list was empty after splitting |
| `<cmd>: bulk input has N ids; the limit is 500` | Split the batch |
| `issue delete: pass an identifier or --bulk, not both` (milestone: `pass a milestone id or --bulk, not both`) | Use one target form |
| `<cmd>: bulk complete; N succeeded, M failed` | Not an error — but the exit code is non-zero when `M > 0` |
| `issue start: issue has no branchName; pass --branch NAME` | Linear returned no branch name for the issue |
| `issue start: team has no workflow state of type 'started'` | The team has no started-type state to move into |
| `issue start: branch 'X' already exists; --from-ref ignored` | Not an error — the existing branch is checked out as-is |
| `issue start: --branch must not start with '-'` (also `must not be empty`, `must not contain whitespace or control characters`) | Ref arguments are validated before git is spawned |
| `issue pr: gh pr create exited with status N` | `gh` failed; its own output already went to the terminal |
| `issue pr: gh was not found on PATH` | Install/authenticate the GitHub CLI |
| `gql: only one of --vars or --vars-file may be provided` | Pick one |
| `gql: cannot use both --query and inline query argument` | Pick one |
| `gql: requested field not found in response` | `--fields` names a key that is not in `data` |
| `gql: response did not include a data field` | The query errored — drop `--data-only` to see `errors` |
| `gql: --paginate cannot be used with a mutation document` | `--paginate` is read-only |
| `gql: --paginate requires the query to declare an $after variable` | Add `($after: String)` and pass it to the connection |
| `gql: --paginate requires the query to select pageInfo { hasNextPage endCursor }` | Select both fields |
| `gql: --paginate requires variables to be a JSON object` | `--vars` must be an object so `after` can be merged in |
| `gql: --paginate found no connection selecting both 'nodes' and 'pageInfo' in the response` | The response has no walkable connection |
| `gql: --paginate stopped after N pages (--max-pages M); more results remain` | Not an error — raise `--max-pages` (default 20) |
| `gql: invalid --max-pages value` | `--max-pages` must be a positive integer |
| `warning: config file ~/.config/linear/config.json permissions should be 0600` | `chmod 600 ~/.config/linear/config.json` |

## Finding IDs

```bash
# Team UUIDs and keys
linear teams list --fields id,key,name

# Project UUIDs
linear projects list --fields id,name --limit 50

# Label / user / workflow-state / milestone UUIDs — no gql needed
linear labels list --team TEAM_KEY --limit 50 --fields id,name --data-only
linear users list --limit 50 --fields id,name,email --data-only
linear states list --team TEAM_KEY --limit 50 --fields id,name,type --data-only
linear milestone list --project "Roadmap" --limit 50 --fields id,name --data-only

# Current user UUID
linear me --json | jq -r '.viewer.id'

# Identifier of the issue on the current branch (no request, no API key)
linear issue id

# Issue UUID from an identifier. Plain --json keeps the raw GraphQL shape and always
# selects `id`; adding --fields replaces it with a flat projection that has no `id` key.
linear issue view ENG-123 --json | jq -r '.issue.id'

# Same thing without fetching the description
linear gql --data-only 'query { issue(id: "ENG-123") { id identifier } }' | jq -r '.issue.id'
```

Or in the Linear app: Cmd/Ctrl+K → "Copy model UUID".

## Inspecting the GraphQL Schema

There is no `linear schema` command. Introspect with `gql`, write to a temp file, and grep it.

`linear gql` pretty-prints by default and **minifies when `--json` is passed** (or when
`default_output` is `json`) — so omit `--json` for anything you intend to grep line-by-line.

```bash
# Every field on a type
linear gql --data-only --operation-name TypeFields --vars '{"name":"Issue"}' '
query TypeFields($name: String!) {
  __type(name: $name) {
    name
    kind
    fields { name description type { name kind ofType { name kind } } }
  }
}' > /tmp/linear-type-Issue.json

grep -n '"name"' /tmp/linear-type-Issue.json | head -60
grep -n -i -A 4 'subscribers' /tmp/linear-type-Issue.json
```

```bash
# Accepted keys on a mutation input object
linear gql --data-only --vars '{"name":"IssueUpdateInput"}' '
query InputFields($name: String!) {
  __type(name: $name) {
    inputFields { name type { name kind ofType { name kind } } }
  }
}' > /tmp/linear-input-IssueUpdateInput.json
grep -n '"name"' /tmp/linear-input-IssueUpdateInput.json
```

```bash
# All type names, to find the one you want
linear gql --data-only 'query { __schema { types { name kind } } }' > /tmp/linear-types.json
grep -n -i 'milestone' /tmp/linear-types.json
```

```bash
# Arguments a root query field accepts
linear gql --data-only --vars '{"name":"Query"}' '
query RootFields($name: String!) {
  __type(name: $name) { fields { name args { name type { name kind ofType { name } } } } }
}' > /tmp/linear-query-root.json
grep -n -A 8 '"issues"' /tmp/linear-query-root.json
```

## JSON Output Structures

Commands with `--json` return nested structures. Use these jq paths:

| Command | Root path | Items path |
|---------|-----------|------------|
| `issue view ID` | `.issue` | N/A (single object) |
| `issue view ID --fields ...` | `.` | N/A (flat object of selected fields) |
| `issue view ID --data-only` | `.` | N/A (flat object; `comments` is an array) |
| `issues list` | `.issues` | `.issues.nodes[]` |
| `issues list --data-only` | `.` | `.nodes[]` (flattened rows, plus `.pageInfo`) |
| `project view ID` | `.project` | N/A (single object) |
| `projects list` | `.projects` | `.projects.nodes[]` |
| `teams list` | `.teams` | `.teams.nodes[]` |
| `labels list` | `.issueLabels` | `.issueLabels.nodes[]` |
| `users list` | `.users` | `.users.nodes[]` |
| `states list` | `.workflowStates` | `.workflowStates.nodes[]` |
| `milestone list` | `.project` | `.project.projectMilestones.nodes[]` |
| `milestone view ID` | `.projectMilestone` | N/A (single object) |
| `issue comment list [ID]` | `.issue` | `.issue.comments.nodes[]` |
| `me` | `.viewer` | N/A (single object) |
| `auth status` | `.` | N/A (flat object; `source`, `key_present`, `key_format_valid`, `key_verified` (always `null`), `credential_helper`, `keychain_supported`, `file_key_present`, `config_path` — no key) |
| `search` | `.issues` | `.issues.nodes[]` |
| `gql --data-only` | `.` (the `data` object) | query-dependent |
| `gql` (no `--data-only`) | `.data` | query-dependent |

`issues list --json` also carries `.pageInfo`, `.limit`, `.maxItems`, and `.sort` alongside `.issues`.

Every enumeration command (`labels list`, `users list`, `states list`, `milestone list`,
`issue comment list`) reshapes under `--data-only --json` into a flat `{"nodes": [...], "pageInfo": {...},
"limit": N}` object — items at `.nodes[]`, keyed by the `--fields` names. That is the only JSON form in
which `issue comment list` bodies stay verbatim *and* are projected.

Bulk `issue delete`/`milestone delete` under `--json` stream a JSON **array** of per-item objects to
stdout; the succeeded/failed summary is suppressed there and only the exit code reports failure.

**Null handling:** Many fields can be null (name, description, dates, assignee). Use null-safe filters.

### jq Patterns

```bash
# List all projects (correct path)
linear projects list --limit 25 --json | jq '.projects.nodes[]'

# Filter projects by name (null-safe)
linear projects list --limit 50 --json | jq '.projects.nodes[] | select(.name) | select(.name | ascii_downcase | contains("keyword"))'

# Get project names as array
linear projects list --limit 50 --json | jq '[.projects.nodes[].name]'

# Filter issues by title
linear issues list --team TEAM --limit 50 --sub-limit 0 --json | jq '.issues.nodes[] | select(.title | ascii_downcase | contains("bug"))'

# Extract specific fields — prefer --fields over jq, it reduces the fetch too
linear issues list --team TEAM --limit 50 --sub-limit 0 --fields identifier,title,state --data-only --json | jq '.nodes[]'
```

**Common mistakes:**
- `.[]` on root - use `.projects.nodes[]` or `.issues.nodes[]`
- `test("pattern"; "i")` on null - filter nulls first with `select(.field)`
- Escaping `!=` in shells - use `select(.field)` instead of `select(.field != null)`
- Filtering with `jq` after fetching everything - use `--fields`/`--limit` so the data is never fetched

## Advanced Operations

For operations not covered by built-in commands, use `linear gql` with GraphQL:

- **Add attachments** - See `graphql-recipes.md` → "Attach URL to Issue"
- **Upload files** - See `graphql-recipes.md` → "Upload File"
- **Walk a large connection** - `linear gql --paginate` (see [Traps](#gql---paginate-validates-the-document-before-it-sends-anything))

Users, labels, workflow states, and milestones no longer need `gql` — use `linear users list`,
`linear labels list`, `linear states list`, and `linear milestone list`. The remaining query forms in
`graphql-recipes.md` → "Bulk Query IDs" cover only the two cases those commands cannot express
(states with their team in one call, milestones across projects).

## Reference Files

- `graphql-recipes.md` - GraphQL mutations for attachments, relations, comments, file uploads, schema introspection
- `troubleshooting.md` - Common errors and debugging steps

## External Links

- [Linear API Docs](https://linear.app/developers/graphql)
- Schema reference: use the `gql` introspection recipes above — no browser required.
