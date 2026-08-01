# Troubleshooting

Common errors and their solutions when using the Linear CLI.

## Table of Contents

1. [Read stderr first](#read-stderr-first)
2. [Authentication Errors](#authentication-errors)
3. [Empty Results](#empty-results)
4. [Branch Inference Errors](#branch-inference-errors)
5. [Content Flag Errors](#content-flag-errors)
6. [Mutation Errors](#mutation-errors)
7. [Bulk Delete Errors](#bulk-delete-errors)
8. [GraphQL Errors](#graphql-errors)
9. [Connection Errors](#connection-errors)
10. [Debugging Steps](#debugging-steps)

---

## Read stderr first

Every diagnostic this CLI emits goes to **stderr**, including the ones that are not errors:

- confirmation refusals (`... confirmation required; re-run with --yes to proceed`)
- pagination notices (`issues list: fetched 25 items across 1 page; more available, resume with --cursor ...`)
- truncation notices (`issue view: comments limited to 10; additional comments omitted`)
- rate-limit details (`...: rate limit: remaining 0/1500; reset in ~42000ms`)
- config permission warnings
- credential-backend diagnostics (`linear: credential_helper '...' exited 1: ...`) and the plaintext-key
  warning (`warning: API key read from ...`), both emitted before the subcommand even starts

A command run as `linear ... | jq` shows none of them, which is why failed mutations read as silent
no-ops. Check the exit code, and keep stderr visible or capture it explicitly:

```bash
linear issue update ENG-123 --assignee me --yes 2>/tmp/linear.err || cat /tmp/linear.err
```

---

## Authentication Errors

### 401 Unauthorized

**Symptom:** stderr shows

```
<cmd>: HTTP status 401
<cmd>: unauthorized (key lin_...abcd); run 'linear auth status' to see which backend supplied it
<cmd>: then replace it: 'linear config set credential_helper "op read op://<vault>/<item>/<field>"' (preferred), 'linear auth set --to keychain' (macOS), or export LINEAR_API_KEY
```

**Causes:**
- API key not configured
- API key expired or revoked
- Wrong API key format

**Solutions:**

```bash
# Which backend supplied the key? Start here — it never prints the key.
linear auth status

# Does that key work? (one `viewer` request)
linear auth test

# Replace the key with one that is not on disk (preferred)
linear config set credential_helper "op read op://<vault>/<item>/<field>"

# macOS, no secret manager: the login keychain (stdin only, never argv)
op read "op://<vault>/<item>/<field>" | linear auth set --to keychain
```

`auth status` is the first command to run for any auth question, because a 401 does not say *which* of the
four backends produced the offending key. It prints the source, whether a key is present and well-formed,
the configured `credential_helper` argv, whether the keychain backend exists on this platform, whether a
plaintext key is still in the config file, and the config path — and exits 1 when no well-formed key was
found:

```
source           : credential_helper
key              : present (format-valid, unverified)
verify           : run 'linear auth test' to check the key against the API
credential_helper: op read op://Private/Linear/api-key
keychain         : /usr/bin/security
file_api_key     : absent
config_path      : /Users/you/.config/linear/config.json
```

`format-valid` is a charset/length check and nothing more — `auth status` makes no network request, so a
revoked key still reports `format-valid`. It answers "where is my credential coming from", not "does it
work"; `linear auth test` answers the second question. A key that fails even the charset check reports
`present (malformed)`. Under `--json` these are `key_present`, `key_format_valid`, and `key_verified`
(always `null`).

**Never print the key.** `linear auth status` answers "where is my credential coming from" without the key
reaching any stream — not stdout, not stderr, not the `--json` object, not even a redacted fingerprint —
so it is the thing to run instead of `auth show`. `auth show` is redacted (`lin_...abcd`; under 16
characters it prints `<redacted>`) including with `--json`, and `--reveal` is refused unless stdout is a
terminal (`auth show: refusing to reveal the API key because stdout is not a terminal`), so in an automated
session it fails instead of leaking. Do not run `linear auth show --reveal`, do not echo `$LINEAR_API_KEY`,
and do not route either through a file or pipe to get around the TTY check. `--redacted` still parses, but
it is a no-op alias.

**Note:** API keys are created at [Linear Settings → API](https://linear.app/settings/api).

### Missing API Key

**Symptom:** stderr shows

```
<cmd>: missing API key; run 'linear auth status' to see which backend is configured
<cmd>: to set one up: 'linear config set credential_helper "op read op://<vault>/<item>/<field>"' (preferred), 'linear auth set --to keychain' (macOS), or export LINEAR_API_KEY
```

**Cause:** no backend in the chain produced a key — *or* a configured one failed. Resolution order,
highest precedence first:

```
LINEAR_API_KEY  ->  credential_helper  ->  keychain (macOS)  ->  config file (deprecated, warns)
```

Run `linear auth status` before doing anything else. `source: none` means nothing is configured;
`source: credential_helper (failed)` means a helper is configured and broke — see
[Credential Helper Failures](#credential-helper-failures), because that state is **not** fixed by
supplying the key somewhere else lower in the chain.

**Solution:**
```bash
# Option 1 (preferred): point a credential_helper at your secret manager.
# The key never touches disk: store it in the manager, then point the helper
# at it. `config set` runs the helper once and refuses to save a broken one.
linear config set credential_helper "op read op://<vault>/<item>/<field>"
linear auth test

# Option 2 (macOS, no secret manager): the login keychain. The key reaches
# `security -i` on stdin, never in an argv, and is read back before this reports
# success. It fails outright off macOS rather than writing the plaintext file.
op read "op://<vault>/<item>/<field>" | linear auth set --to keychain

# Option 3: environment variable (read on every run, never written to the config file)
export LINEAR_API_KEY="lin_api_..."
linear auth test

# Option 4 (deprecated as a destination): store it in the config file, plaintext
linear auth set            # same as `linear auth set --to file`
```

Prefer option 1: it is the only route where the key is never written to disk at all. Option 4 stores the
key in cleartext and makes the CLI warn on every run that reads it (`warning: API key read from ...; the
config file stores it in plaintext.`); reach for it only when neither a secret manager nor the keychain is
available. A literal key typed after `export` lands in shell history and in the environment of every child
process.

Nothing but the config file is ever written to disk: a key from the environment, a helper, or the keychain
is never persisted, and a key already in the config file survives saves made while one of them is
supplying the effective value.

**Note:** there is no `--api-key` flag — keys are never accepted on argv, where
they would leak into `ps` output and shell history.

### Credential Helper Failures

**Symptom:** every API command reports `missing API key`, and stderr carries one of these first (`CMD` is
the configured argv, joined for display — it is configuration, not a secret):

```
linear: credential_helper 'CMD' was not found on PATH
linear: credential_helper 'CMD' could not be started
linear: credential_helper 'CMD' did not finish in time
linear: credential_helper 'CMD' exited 1: <first line of the helper's stderr>
linear: credential_helper 'CMD' produced no output
linear: credential_helper 'CMD' produced more than 512 characters, which cannot be an API key
linear: credential_helper 'CMD' produced something that is not a valid API key; expected 4-512 characters from [A-Za-z0-9_-]
```

**Cause:** a configured helper that fails **clears the effective key instead of falling through**. Falling
back would silently reinstate the plaintext config-file key the helper was configured to replace, so the
chain stops at the failure. The keychain is not tried either. The key on disk is left untouched, so
`auth status` still reports `file_api_key: present (deprecated plaintext)`.

The helper's **stdout is never printed, logged, or quoted** — that is where the secret is. Only the exit
status and the first line of stderr (200 bytes, control bytes stripped) reach the diagnostic.

**The escape hatch:** neither of these needs a key, so both still work in this state — the diagnostic and
the fix are always reachable.

```bash
linear auth status                        # source: credential_helper (failed); exits 1
linear config unset credential_helper     # drop the helper; the next backend takes over
```

**Solution:** run the helper by hand and confirm it prints the bare key on stdout and nothing else.

```bash
op read "op://<vault>/<item>/<field>" | wc -c    # length only — do not print the key
```

Common causes, in order of likelihood:

- Vault locked or session expired → the helper exits non-zero; its own stderr is quoted in the diagnostic.
- Wrong item path → same shape, `exited 1: ...`.
- The helper prints JSON, a banner, or a `Warning:` line alongside the key → `produced something that is
  not a valid API key`, or `produced more than 512 characters`.
- The helper waits on a biometric/2FA prompt nobody answers → `did not finish in time` after the 60 s
  budget. It is killed, not retried.
- The value was written as a shell pipeline → the shell metacharacters were passed to the binary as
  ordinary argv elements. `credential_helper` is argv, not a command line: no quoting, no pipes, no
  `$VAR`, no globs. Wrap the pipeline in a script and point the helper at the script.

**Config-file syntax errors** show up earlier, at load time, with the error name rather than a sentence:

```
failed to load config: EmptyCredentialHelper
failed to load config: TooManyCredentialHelperArgs
failed to load config: InvalidCredentialHelperArg
failed to load config: InvalidCredentialHelper
```

The bounds are 16 argv elements, 1024 bytes per element, no empty elements, and the value must be a JSON
array of strings — or a bare string, which is split on ASCII whitespace with the same no-shell rule.

### Getting Off a Plaintext Key

**Symptom:** every run prints

```
warning: API key read from /Users/you/.config/linear/config.json; the config file stores it in plaintext.
warning: delete /Users/you/.config/linear/config.json to clear it (it also holds default_team_id and team_cache), then set up a backend that keeps the key off disk: 'linear config set credential_helper "op read op://<vault>/<item>/<field>"' (preferred) or 'linear auth set --to keychain'. Rotate the old key in Linear either way.
```

**Cause:** the deprecated file backend is what supplied the key. It warns every single time.

**There is no `auth migrate`.** It was removed, and it should not be reconstructed by hand. Moving the key
would still leave it disclosed: the CLI cannot un-write a file, and overwriting the bytes in place does not
beat APFS copy-on-write, snapshots, Time Machine, or a synced folder that already captured it. The key has
to be **rotated in Linear** regardless — and once it is being replaced, carrying the old one over to a
nicer backend buys nothing. Deleting the file also clears the cruft that came with it (`default_team_id`,
`team_cache`).

**Solution — three steps, in this order:**

```bash
# 1. Put the key in a secret manager, and rotate the old one in Linear.

# 2. Delete the config file. default_team_id and team_cache live there too, so
#    they go with it.
rm ~/.config/linear/config.json

# 3. Set up again from scratch, then confirm what is live now.
linear config set credential_helper "op read op://<vault>/<item>/<field>"
#    macOS with no secret manager, instead of the helper:
#    op read "op://<vault>/<item>/<field>" | linear auth set --to keychain
linear config set default_team_id TEAM_KEY
linear auth status        # source: credential_helper (or keychain)
linear auth test
```

**Delete before you configure, not after.** `credential_helper` is stored *in* `config.json`, so setting
it first and deleting the file afterwards throws the new helper away along with the old key. `auth set
--to keychain` writes nothing to the config file, so either order works for it — but the order above is
correct for both.

**What the keychain does and does not buy you.** `auth set --to keychain` stores the key as a generic
password (service `linear-cli`, account `api-key`) through `/usr/bin/security`, and the secret never
appears in an argv on either the read or the write path — the write hands `security -i` its
`add-generic-password` line on stdin. The item is read back and compared before the command reports
success. The win is **encryption at rest** and immunity to accidental disclosure — backups, synced
folders, a stray `cat` of the config, a screen share. It is **not** process isolation: the item is created
through `security`, so it is ACL'd to `/usr/bin/security`, and any process running as you can read it back
non-interactively with no prompt. The backend does not exist on Linux or Windows (`auth set: the keychain
backend is only available on macOS; use 'linear config set credential_helper "<command>"' instead`) — it
fails there rather than quietly writing the plaintext file.

**`auth set --to keychain` refusals** — none of these store anything:

```
auth set: UnknownBackend                                   # --to takes keychain or file, nothing else
auth set: the keychain backend is only available on macOS; use 'linear config set credential_helper "<command>"' instead
auth set: the keychain read back a different key than was written; the item holds something else
auth set: the keychain item could not be read back after writing it; nothing was stored
auth set: this API key starts with '-', which /usr/bin/security would read as an option; put it in a secret manager and use 'linear config set credential_helper "<command>"' instead
auth set: process execution is unavailable
```

The two read-back refusals are the important ones: `security -i` reports on the session rather than on
each command it was fed, so an exit-0 write that stored nothing would otherwise look like success.

### Invalid API Key Format

**Symptom:** stderr shows one of

```
auth set: invalid API key; expected 4-512 characters from [A-Za-z0-9_-]
failed to load config: api key must be 4-512 characters from [A-Za-z0-9_-]
```

**Cause:** the key is validated on every ingestion path — `auth set`, the config file, `LINEAR_CONFIG`,
`LINEAR_API_KEY`, and every credential backend (a helper's stdout and the keychain item are checked before
either can become the effective key). Anything outside `[A-Za-z0-9_-]` is rejected, notably a trailing `\r`
from a Windows-authored file or a wrapped/quoted paste, because those bytes reach the `Authorization`
header.

**Solution:** re-supply the bare key with no quotes or trailing newline junk. `auth set` writes nothing to
disk when validation fails, so the previous config is intact. When a helper is the source, the message is
`linear: credential_helper 'CMD' produced something that is not a valid API key; ...` instead — see
[Credential Helper Failures](#credential-helper-failures).

```bash
op read "op://<vault>/<item>/<field>" | linear auth set
```

---

## Empty Results

### No Issues Returned

**Symptom:** `linear issues list` returns 0 items, or stderr shows
`issues list: missing team selection` / `issues list: team 'X' not found`.

**Causes:**
1. No team specified and no default team set (`issues list: missing team selection`)
2. All issues are completed/canceled (filtered by default)
3. Wrong team key/ID (`issues list: team 'X' not found`)
4. A `--state` value that is a state *name* rather than a state *type* — `--state` on `issues list` is an
   alias of `--state-type` and only accepts `triage,backlog,unstarted,started,completed,canceled`
5. An `--updated-since`/`--created-since` boundary that excludes everything. Both compare **strictly
   greater than**, so an issue stamped exactly at the boundary is filtered out, and the value is
   forwarded to Linear verbatim — a non-ISO-8601 string is rejected by the API, not by the CLI

**Solutions:**

```bash
# List available teams first
linear teams list --fields id,key

# Specify team explicitly
linear issues list --team TEAM_KEY --limit 20 --sub-limit 0

# Include all issues (including completed/canceled)
linear issues list --team TEAM_KEY --limit 20 --sub-limit 0 \
  --state-type backlog,unstarted,started,completed,canceled

# Filter on one specific workflow state (needs a state UUID, not a name)
linear states list --team TEAM_KEY --limit 50 --fields id,name,type --data-only
linear issues list --team TEAM_KEY --state-id <STATE_UUID> --limit 20 --sub-limit 0

# Widen a time filter (both are exclusive) and sort explicitly
linear issues list --team TEAM_KEY --updated-since 2026-01-01T00:00:00Z \
  --sort updated:desc --limit 20 --sub-limit 0
```

The same applies to the other id-only filters — `linear labels list --team KEY`,
`linear users list`, and `linear milestone list [--project ID|NAME]` enumerate the candidates for
`--label`, `--assignee`, and `--milestone`. Add `--quiet` for bare ids. No `gql` query is needed for any
of them.

### No Labels / Users / States / Milestones Returned

**Symptom:** an enumeration command prints nothing, or stderr shows one of

```
labels list: invalid --team value
milestone list: project 'X' not found
milestone list: project 'X' is ambiguous; pass the project id
labels list: fetched 50 items across 1 page; more available, resume with --cursor XXX
```

**Causes and fixes:**

- `--team` filters `labels list` and `states list` on the team's key or id, so a workspace-level label
  that belongs to no team is excluded by it — drop `--team` to see those. `users list` has no `--team`.
- `users list` hides deactivated members by default. Add `--include-inactive` to see them.
- `milestone list --project` is optional; without it the listing spans every project, and the `Project`
  column tells the rows apart. A non-UUID value is matched against the project slug or its exact name.
  Two matches is an error — take the id from `linear projects list --fields id,name`.
- These commands paginate. The "more available" notice means the walk hit its page budget (one page by
  default), not that rows were lost: re-run with `--all`, `--pages N`, or `--cursor XXX` to continue.
  `--max-items N` caps the total if you only want a bounded slice.

```bash
linear labels list --team TEAM_KEY --limit 100 --fields id,name --data-only
linear users list --include-inactive --limit 100 --fields id,email,active --data-only
linear states list --team TEAM_KEY --limit 50 --data-only
linear milestone list --project "Roadmap" --limit 50 --data-only
```

### Issue Not Found

**Symptom:** `issue view: issue not found`, or
`issue view: invalid issue identifier; expected TEAM-NUMBER`.

**Causes:**
- Malformed identifier — it must be `TEAM-NUMBER` (`ENG-123`) or a UUID/CUID
- Issue was archived or deleted
- No access to that issue

**Solutions:**
```bash
# Use identifier format (preferred); cheap existence check
linear issue view ENG-123 --fields identifier,state --data-only

# If you have a UUID, it also works
linear issue view "uuid-string-here" --fields identifier --data-only
```

---

## Branch Inference Errors

`issue view`, `issue update`, `issue link`, `issue comment`, `issue comment list`, `issue start`,
`issue pr`, and `issue id|url|title|describe` fall back to the current git branch when the identifier is
omitted. When that fails, they say so and exit 1 rather than guessing:

```
issue view: branch 'main' has no issue identifier; pass one explicitly
issue view: HEAD is detached; pass an issue identifier explicitly
issue view: not a git repository; pass an issue identifier explicitly
issue view: git was not found on PATH; pass an issue identifier explicitly
```

**Cause:** the branch name has to contain a leftmost `TEAM-123` match — the convention Linear's own
`Issue.branchName` uses. `_` counts as a word character, so `feat_eng-123` does **not** match, and a
leading zero is not a valid issue number, so `eng-0123` does **not** match. The team key is uppercased in
the result (`eng-123` → `ENG-123`).

**Solution:** pass the identifier explicitly, or check out a branch whose name carries it.

```bash
linear issue id            # what inference would resolve to; makes no API request
git branch --show-current
linear issue view ENG-123  # explicit, and always correct
```

`issue delete` never infers — it always needs an explicit target or a `--bulk*` source
(`issue delete: missing identifier or id`).

---

## Content Flag Errors

**Symptom:** stderr shows one of

```
issue create: cannot use both --description and --description-file
issue create: file 'body.md' exceeds the 1048576 byte limit
issue create: stdin exceeds the 1048576 byte limit
issue create: cannot read file 'body.md': FileNotFound
```

**Cause:** every long-form flag has an inline form and a `-file` twin — `--description`/`--description-file`
(`issue create`, `issue update`, `milestone create`, `milestone update`), `--body`/`--body-file`
(`issue comment`, `issue comment update`), `--content`/`--content-file` (`project create`,
`project update`). Supplying both is rejected rather than resolved by precedence, so a mistyped
invocation can never quietly send the wrong content. The file/stdin cap is 1 MiB.

**Solution:** pick one form. `-` reads stdin on every `--*-file` flag.

```bash
cat body.md | linear issue update ENG-123 --description-file - --yes --quiet
linear project update PROJECT_ID --content-file overview.md --yes --quiet
```

Note that `--description` on `project create`/`project update` is capped at 255 characters by Linear
itself; `--content`/`--content-file` is the uncapped long-form field.

---

## Mutation Errors

### Mutation Does Nothing

**Symptom:** `issue create`, `issue update`, or `issue delete` produces no stdout and changes nothing.

**Cause:** Mutations require explicit confirmation. The refusal goes to stderr and exits 1:

```
issue create: confirmation required; re-run with --yes to proceed
issue update: confirmation required; re-run with --yes to proceed
issue delete: confirmation required; re-run with --yes to proceed
```

The same message is emitted by `issue link`, `issue comment`, `issue comment update|delete`,
`issue start`, `issue pr`, `project create|update|delete`, `project add-issue|remove-issue`,
`milestone create|update|delete`, and `gql` when the document declares a top-level `mutation`.

**Solution:** Add `--yes` (alias `--force`):
```bash
linear issue create --team OUT --title "Task" --yes --quiet
linear issue delete ENG-123 --yes
linear gql --query /tmp/mutation.graphql --vars '{"id":"UUID"}' --yes
```

`gql --dry-run` prints what would be sent and exits 0 without a request, so it satisfies the gate by
itself — use it to check a mutation document before adding `--yes`. Detection looks only at top-level
tokens and skips `#` comments and string literals, so a field named `mutation` inside a selection set will
not trigger the prompt, and a read-only query never needs `--yes`.

`issue delete` calls the `issueDelete` mutation, which moves the issue to Linear's trash rather than
hard-deleting it. Validate the target first with `--dry-run`, which resolves the issue, prints it, and
exits 0 without mutating:

```bash
linear issue delete ENG-123 --dry-run
linear milestone delete MILESTONE_ID --dry-run
```

### Missing Required Fields

**Required fields for `issue create`:** `--team` (id or key), `--title`, `--yes`.

```bash
linear issue create --team OUT --title "My task" --yes --quiet
```

**`issue update` with no field flags:**

```
issue update: at least one field to update is required
```

Supply at least one of `--assignee`, `--parent`, `--state`, `--priority`, `--title`, `--description`,
`--description-file`, `--project`.

**Required fields for `milestone create`:** `--project` (id, slug, or exact name), `--name`, `--yes`.

```
milestone create: --project is required
milestone create: --name is required
milestone update: provide at least one of --name, --description, --description-file, --target-date, or --sort-order
```

**`issue start` prerequisites:** the issue needs a Linear `branchName` and the team needs a workflow
state of type `started`.

```
issue start: issue has no branchName; pass --branch NAME
issue start: team has no workflow state of type 'started'
issue start: branch 'X' already exists; --from-ref ignored
issue start: git checkout failed for branch 'X'
```

The `--from-ref` notice is informational: an existing branch is checked out as-is and the base ref is
ignored. `--branch` and `--from-ref` are validated before git is spawned — a value that is empty, starts
with `-`, or contains whitespace/control characters is refused
(`issue start: --branch must not start with '-'`).

### Wrong Workflow State Name

**Symptom:**

```
issue update: state 'started' not found; available states: Todo, In Progress, In Review, Done, Canceled
```

**Cause:** `issue update --state` takes a state **name** (case-insensitive) or a state id — not a state
*type*. `started` is a type, valid only for `issues list --state-type`.

**Solution:** Use one of the names the error lists verbatim: `linear issue update ENG-123 --state "In Progress" --yes`.

### `--parent` Not Found

**Symptom:** `issue update: issue 'ENG-100' not found`.

**Cause:** `--parent` accepts an identifier *or* an id — the CLI resolves `ENG-100` through the same
lookup as the positional argument before sending `parentId`. The error therefore means the parent does
not exist or is not visible, not that the format was wrong.

**Solution:** confirm the parent first, then set it.

```bash
linear issue view ENG-100 --fields identifier,state --data-only
linear issue update ENG-123 --parent ENG-100 --yes
```

### Comment Body Comes Back Mangled

**Symptom:** a comment read through `issue comment list` has lost its line breaks.

**Cause:** table output and tab-separated `--data-only` output are single-line records, so `\r`, `\n`,
and `\t` inside a body are folded to spaces. This is display formatting, not data loss at the source.

**Solution:** read bodies as JSON — verbatim there, including with `--data-only --json`.

```bash
linear issue comment list ENG-123 --limit 20 --json | jq -r '.issue.comments.nodes[].body'
linear issue comment list ENG-123 --limit 20 --fields id,body --data-only --json
```

---

## Bulk Delete Errors

`issue delete` and `milestone delete` accept `--bulk ID,ID`, `--bulk-file PATH`, and `--bulk-stdin`.

**Symptom:** stderr shows one of

```
issue delete: use only one of --bulk, --bulk-file, or --bulk-stdin
issue delete: bulk input contained no ids
issue delete: bulk input has 900 ids; the limit is 500
issue delete: pass an identifier or --bulk, not both
milestone delete: pass a milestone id or --bulk, not both
issue delete: bulk complete; 3 succeeded, 1 failed
```

**Behavior to expect:**

- Execution is **serial**, in input order. Ids are deduplicated keeping first-seen order, so the same
  destructive mutation is never sent twice.
- Input is split on commas and ASCII whitespace, so `--bulk a,b` and a newline-delimited file both work.
- The batch is capped at 500 ids; the bulk source is read and validated **before** any network call.
- A failed item is counted and the run **continues**. The final line is a summary, and the exit code is
  non-zero when anything failed.
- The summary is suppressed under `--json`, where stdout is a streamed JSON array instead — the exit
  code is then the only failure signal.

**Solution:** dry-run first (no `--yes` needed, nothing is sent), then check `$?`.

```bash
linear issues list --team TEAM_KEY --limit 25 --quiet | linear issue delete --bulk-stdin --dry-run
linear issue delete --bulk ENG-1,ENG-2 --yes --quiet
echo $?
```

---

## GraphQL Errors

### Invalid Query Syntax

**Symptom:** `gql: Syntax Error: ...` on stderr, exit 1.

**Solutions:**
1. Check for missing braces or typos
2. Ensure variable types match the schema — confirm with the introspection recipes in
   `graphql-recipes.md` → "Schema Introspection"
3. Put the query in a file and pass `--query FILE` to avoid shell-quoting damage:
   ```bash
   cat > /tmp/q.graphql << 'EOF'
   query Viewer { viewer { id name } }
   EOF
   linear gql --query /tmp/q.graphql --data-only
   ```

### `gql` Flag Conflicts

```
gql: only one of --vars or --vars-file may be provided
gql: cannot use both --query and inline query argument
```

Pick one form for each.

### `gql: response did not include a data field`

The query errored, and `--data-only` suppressed the `errors` array. Re-run without `--data-only` to see it.

### `gql: requested field not found in response`

`--fields` names a key that is not a top-level key of the payload. `gql --fields` selects top-level keys of
the response object — it is not the same projection vocabulary as `issues list --fields`.

### `--paginate` Rejected Before Any Request

**Symptom:** one of

```
gql: --paginate cannot be used with a mutation document
gql: --paginate requires the query to declare an $after variable
gql: --paginate requires the query to select pageInfo { hasNextPage endCursor }
gql: --paginate requires variables to be a JSON object
gql: invalid --max-pages value
```

**Cause:** the walk is validated up front — before the first request and before an API key is even
required — so a query that cannot be paginated fails immediately instead of quietly returning page one.
The document must be read-only, declare `$after` and pass it to the connection, and select all three of
`pageInfo`, `hasNextPage`, `endCursor`. `--vars` must be a JSON object so the cursor can be merged in.

**Solution:**

```bash
linear gql --paginate --max-pages 5 --data-only '
query TeamIssues($after: String) {
  issues(first: 50, after: $after) {
    nodes { identifier title }
    pageInfo { hasNextPage endCursor }
  }
}'
```

### `--paginate` Failures Mid-Walk

```
gql: --paginate found no connection selecting both 'nodes' and 'pageInfo' in the response
gql: --paginate lost the connection on page 3
gql: --paginate found no 'nodes' array on page 3
gql: --paginate needs an endCursor to continue but the page did not return one
gql: --paginate stopped after 20 pages (--max-pages 20); more results remain
```

The connection to walk is discovered breadth-first, so the **shallowest** one wins and a connection
nested inside an array is never chosen. The last message is not an error — `--max-pages` defaults to 20
and merged results up to that point are still printed. A page that returns an HTTP or GraphQL error
stops the walk and is reported exactly as an unpaginated run would report it.

### Variable Type Mismatch

**Symptom:** "Variable $x got invalid value" error.

**Common issues:**
- String where ID expected (use UUID, not identifier)
- Missing required variables
- Wrong enum value

```bash
# Wrong: using identifier
--vars '{"issueId":"ENG-123"}'

# Correct: using UUID
--vars '{"issueId":"abc123-uuid-here"}'
```

### Field Not Found

**Symptom:** "Cannot query field X on type Y"

**Cause:** Field doesn't exist or is named differently.

**Solution:** Introspect the type. There is no `linear schema` command — write the introspection result to
a temp file and grep it:

```bash
linear gql --data-only --vars '{"name":"Issue"}' '
query TypeFields($name: String!) {
  __type(name: $name) { fields { name type { name kind ofType { name kind } } } }
}' > /tmp/linear-type-Issue.json

grep -n '"name"' /tmp/linear-type-Issue.json
```

Omit `--json` so the output stays pretty-printed and greppable; `--json` minifies it onto one line.
For mutation inputs, query `inputFields` instead of `fields` — see `graphql-recipes.md` →
"Schema Introspection".

---

## Connection Errors

### Timeout

**Symptom:** `<cmd>: request timed out after 10000ms` (10000 ms is the default).

**Solutions:**
```bash
# Increase timeout (milliseconds)
linear issues list --team TEAM --limit 20 --sub-limit 0 --timeout-ms 30000

# Retry on failure (retries apply to 5xx only; default 0)
linear issues list --team TEAM --limit 20 --sub-limit 0 --retries 3

# Or shrink the request — often the real fix
linear issues list --limit 10 --sub-limit 0 --fields identifier,title
```

### Rate Limited

**Symptom:**

```
<cmd>: HTTP status 429
<cmd>: rate limit: remaining 0/1500; reset in ~42000ms
```

**Solution:** wait for the printed reset window. Reduce request volume with `--limit`, `--max-items`, and
`--sub-limit 0` rather than retrying immediately.

### Rejected `--endpoint`

**Symptom:** the command exits 1 before any request, with one of

```
linear: --endpoint rejected: endpoint must use https; set LINEAR_ALLOW_INSECURE_ENDPOINT=1 to allow other schemes
linear: --endpoint rejected: endpoint host must be api.linear.app; set LINEAR_ALLOW_INSECURE_ENDPOINT=1 to allow other hosts
linear: --endpoint rejected: endpoint must be an absolute URL with a host
```

**Cause:** `--endpoint` is allowlisted. Every request carries the API key in an `Authorization` header, so
the URL is checked before a connection is opened: it must use `https` and resolve to host
`api.linear.app`. Look-alikes are rejected too — `https://api.linear.app.evil.example.com/graphql` and
`https://api.linear.app@evil.example.com/graphql` both fail the host check.

**Solution:** drop `--endpoint`; the default (`https://api.linear.app/graphql`) is what you want. Only a
mock/QA server needs `LINEAR_ALLOW_INSECURE_ENDPOINT=1` (the literal `1`, nothing else), and even then the
value must still parse as a URL with a host.

### Network Errors

**Symptom:** Connection refused or network unreachable.

**Solutions:**
1. Check internet connection
2. Verify Linear API is up: https://status.linear.app
3. Check if corporate firewall blocks `api.linear.app`

---

## Debugging Steps

### Step 1: Verify Authentication
```bash
linear auth status   # which backend, and is the key well-formed — offline, never prints the key
linear auth test     # does the key actually authenticate — the only real check
```

Expected: `auth status` exits 0 and names a source; `auth test` shows your user info. `auth status` alone
is not proof the key works: it never leaves the machine, so `format-valid (unverified)` covers a revoked
key too. If `auth status` reports `source: credential_helper (failed)`, stop here — nothing downstream will
work until the helper is fixed or unset.

### Step 2: Check Team Access
```bash
linear teams list
```

Verify your team appears in the list.

### Step 3: Test Simple Query
```bash
linear me
```

Should show your user details.

### Step 4: Check Issue Exists
```bash
linear issue view ISSUE-ID --fields identifier,state --data-only
```

### Step 5: Enable Verbose Output
```bash
# Get full JSON response (bound it — --all/--pages multiply the cost)
linear issues list --team TEAM --limit 10 --sub-limit 0 --json

# For GraphQL, check the raw response including the errors array
echo 'query { viewer { id } }' | linear gql --json
```

### Step 6: Confirm the Command's Own Flag Set

Before assuming a flag is broken, confirm it exists. Every command's usage block ends with an
`Examples:` section (the only exceptions are `linear help config` and `linear help config show`):

```bash
linear help issues
linear help issue view
linear help issue comment list
linear help issue start
linear help labels          # also: users, states
linear help milestone       # all five subcommands in one block
linear help search
linear help gql
```

`search: unknown flag` and `issues list: unknown flag` mean the flag does not exist on that command —
`--plain`, `--no-truncate`, `--quiet`, and `--data-only` are **not** accepted by `search`, and
`--comment-limit` exists only on `issue view`. Likewise `--team` does not exist on `users list`,
`--include-inactive` exists only there, `--bulk*` exists only on `issue delete` and `milestone delete`,
and `--paginate`/`--max-pages` exist only on `gql`.

### Step 7: Introspect the Schema

For anything `gql`-related, dump the relevant type to a temp file and grep it — see
`graphql-recipes.md` → "Schema Introspection". No browser or external explorer is needed.

---

## Config File Issues

### Location
Config is stored at `~/.config/linear/config.json`.

### Check Current Config
```bash
linear config show
```

Prints `config_path`, `default_team_id`, `default_output`, `default_state_filter`, and the
`credential_helper` argv — never the API key. Do not `cat` the config file: if the deprecated `api_key`
field is still there it holds the key in cleartext, and dumping it puts a live credential into the
transcript. `linear auth status` answers which backend the key comes from without printing it, and
`file_api_key: present (deprecated plaintext)` in that output is what tells you the file still holds one.

`credential_helper` can be set and unset here. `config set` runs the helper once before storing it and
refuses to save one that fails, prints nothing, or prints something that is not a key — a stored-but-broken
helper clears the effective key rather than falling through, so it would lock you out:

```bash
# Bootstrap a helper with the key never touching disk.
linear config set credential_helper "op read op://<vault>/<item>/<field>"

# The escape hatch, which needs no key and spawns nothing.
linear config unset credential_helper
```

The value is split on ASCII whitespace into argv with **no** shell semantics (quotes, pipes, `;`, `$VAR`
are ordinary bytes), capped at 16 arguments of 1024 bytes each, and those bounds are checked before
anything is spawned.

### Reset Config
```bash
rm ~/.config/linear/config.json
linear auth status
```

Removing the file drops `credential_helper` along with the defaults, so re-point the helper afterwards
with `linear config set credential_helper "<command>"` — that needs no key on disk. A **keychain** item is
not stored in the config file and survives the delete — on macOS `linear auth status` may well still
report `source: keychain` with no config file at all.

Deleting the file is not a secure erase of a key it contained — see
[Getting Off a Plaintext Key](#getting-off-a-plaintext-key) and rotate the key.

### Permission Issues
Config should have mode 0600. If warnings appear:
```bash
chmod 600 ~/.config/linear/config.json
```
