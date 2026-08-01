# GraphQL Recipes

Advanced operations using `linear gql` for functionality not covered by built-in commands.

## Table of Contents

1. [Link Two Issues](#link-two-issues)
2. [Attach URL to Issue](#attach-url-to-issue)
3. [Add Comment](#add-comment)
4. [Upload File](#upload-file)
5. [Set Issue Parent](#set-issue-parent)
6. [Query Issue Relations](#query-issue-relations)
7. [Assign Issue](#assign-issue)
8. [Bulk Query IDs](#bulk-query-ids) — mostly superseded by `labels|users|states|milestone list`
9. [Schema Introspection](#schema-introspection)

---

## `linear gql` flags

Confirmed flags (`linear help gql`):

| Flag | Effect |
|------|--------|
| `QUERY` (positional) | Inline query string |
| `--query FILE` | Read the query from a file (mutually exclusive with the positional form) |
| `--vars JSON` | Inline JSON variables |
| `--vars-file FILE` | JSON variables from a file (mutually exclusive with `--vars`) |
| `--data-only` | Print only the `data` payload, dropping the `{"data": ...}` envelope |
| `--fields LIST` | Keep only these top-level keys of the payload |
| `--operation-name NAME` | Set `operationName` (needed when the document has several operations) |
| `--paginate` | Follow `pageInfo.endCursor` and merge every page's `nodes` into the first page's document |
| `--max-pages N` | Cap on `--paginate` requests (default: 20) |
| `--yes` | **Required for any document with a top-level `mutation`** (alias: `--force`) |
| `--dry-run` | Report the operation and exit 0 without sending a request; satisfies the gate on its own |

With no query source and no positional argument, `gql` reads the query from stdin.

Every mutation recipe below therefore carries `--yes`. Without it, `gql` prints
`gql: confirmation required; re-run with --yes to proceed` to **stderr** and exits 1 with empty stdout —
which a `| jq` pipeline hides. Never add `--yes` to a read-only query; the [Bulk Query IDs](#bulk-query-ids)
and [Schema Introspection](#schema-introspection) recipes are queries and stay as written.

Output shape: `gql` **pretty-prints by default and minifies when `--json` is passed** (or when
`default_output` is `json`). Omit `--json` when you intend to `grep` the output; pass it when piping to `jq`.

### `--paginate`

`--paginate` re-issues the query with each returned `endCursor` and merges the connection's `nodes`
arrays into the first page's document. Three conditions are validated **up front** — before the first
request, and before an API key is even required:

1. the document must not be a mutation,
2. it must declare an `$after` variable and pass it to the connection,
3. it must select `pageInfo { hasNextPage endCursor }`.

The connection to walk is found breadth-first, so the **shallowest** one in the response wins; a
connection nested inside an array is never selected. `--vars`, when given, must be a JSON object so the
cursor can be merged into it. Hitting `--max-pages` (default 20) is reported on stderr and is not an
error.

```bash
linear gql --paginate --max-pages 5 --data-only '
query TeamIssues($after: String) {
  issues(first: 50, after: $after) {
    nodes { identifier title }
    pageInfo { hasNextPage endCursor }
  }
}'
```

---

## Link Two Issues

**CLI alternative:** `linear issue link ID|IDENTIFIER --blocks|--related|--duplicate OTHER_ID --yes`

Creates relationships between issues. Relation types: `blocks`, `duplicate`, `related`.

```bash
cat > /tmp/link-issues.graphql << 'EOF'
mutation LinkIssues($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
  issueRelationCreate(input: {
    issueId: $issueId
    relatedIssueId: $relatedIssueId
    type: $type
  }) {
    success
    issueRelation { id type }
  }
}
EOF

# Issue A blocks Issue B
linear gql --query /tmp/link-issues.graphql \
  --vars '{"issueId":"ISSUE-A-UUID","relatedIssueId":"ISSUE-B-UUID","type":"blocks"}' \
  --yes --json

# Mark as duplicate
linear gql --query /tmp/link-issues.graphql \
  --vars '{"issueId":"UUID","relatedIssueId":"UUID","type":"duplicate"}' \
  --yes --json
```

---

## Attach URL to Issue

Links external resources (PRs, docs, designs) to an issue.

```bash
cat > /tmp/attach.graphql << 'EOF'
mutation AttachLink($issueId: String!, $url: String!, $title: String!) {
  attachmentCreate(input: {
    issueId: $issueId
    url: $url
    title: $title
  }) {
    success
    attachment { id url title }
  }
}
EOF

linear gql --query /tmp/attach.graphql \
  --vars '{"issueId":"UUID","url":"https://github.com/org/repo/pull/123","title":"PR: Feature"}' \
  --yes --json
```

Optional fields in input: `subtitle`, `iconUrl`, `metadata`.

---

## Add Comment

**CLI alternative:** `linear issue comment [ID] --body TEXT|--body-file PATH [--parent COMMENT_ID] --yes`.
Reading, editing, and removing comments are covered too — `linear issue comment list [ID]`,
`linear issue comment update COMMENT_ID --body TEXT --yes`, and
`linear issue comment delete COMMENT_ID --yes`. Prefer them; `gql` is only needed for fields those
commands do not expose.

Adds a comment to an issue.

```bash
cat > /tmp/comment.graphql << 'EOF'
mutation AddComment($issueId: String!, $body: String!) {
  commentCreate(input: {
    issueId: $issueId
    body: $body
  }) {
    success
    comment { id body createdAt }
  }
}
EOF

linear gql --query /tmp/comment.graphql \
  --vars '{"issueId":"UUID","body":"Root cause identified in auth module."}' \
  --yes --json
```

---

## Upload File

Three-step process: request signed URL, upload file, use asset URL.

### Step 1: Get upload URL

The `fileUpload` mutation returns an `UploadPayload` with a nested `uploadFile` object:

```bash
cat > /tmp/file-upload.graphql << 'EOF'
mutation RequestUpload($filename: String!, $contentType: String!, $size: Int!) {
  fileUpload(filename: $filename, contentType: $contentType, size: $size) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers { key value }
    }
  }
}
EOF

linear gql --query /tmp/file-upload.graphql \
  --vars '{"filename":"screenshot.png","contentType":"image/png","size":12345}' \
  --yes --json > /tmp/upload-response.json
```

### Step 2: Upload to signed URL

**Important:** Include ALL headers from the response to avoid 403 Forbidden errors.

```bash
# Extract uploadUrl and headers from response.uploadFile, then:
# Include every header returned (x-goog-*/x-amz-* and Content-Disposition)
curl -X PUT "UPLOAD_URL_FROM_RESPONSE" \
  -H "Content-Type: image/png" \
  -H "HEADER_KEY_FROM_RESPONSE: HEADER_VALUE" \
  --data-binary @screenshot.png
```

### Step 3: Use asset URL

The `assetUrl` from `uploadFile` can be embedded in markdown:
```markdown
![screenshot](ASSET_URL)
```

Use in issue description or comment body.

**Note:** Accessing `assetUrl` outside the Linear app requires an `Authorization: <API key>` header; unauthenticated requests return 401.

---

## Set Issue Parent

**CLI alternative:** `linear issue update CHILD_ID --parent ENG-100|PARENT_ID --yes` — `--parent` is
resolved from an identifier, so no UUID lookup is needed first.

Makes an issue a sub-issue of another.

```bash
cat > /tmp/set-parent.graphql << 'EOF'
mutation SetParent($issueId: String!, $parentId: String!) {
  issueUpdate(id: $issueId, input: { parentId: $parentId }) {
    success
    issue { id identifier parent { identifier } }
  }
}
EOF

linear gql --query /tmp/set-parent.graphql \
  --vars '{"issueId":"CHILD-UUID","parentId":"PARENT-UUID"}' \
  --yes --json
```

---

## Query Issue Relations

Fetches an issue with its parent, children, and linked issues.

```bash
cat > /tmp/issue-relations.graphql << 'EOF'
query IssueWithRelations($id: String!) {
  issue(id: $id) {
    identifier
    title
    parent { identifier title }
    children(first: 10) { nodes { identifier title } }
    relations(first: 10) {
      nodes {
        type
        relatedIssue { identifier title }
      }
    }
  }
}
EOF

linear gql --query /tmp/issue-relations.graphql \
  --vars '{"id":"UUID"}' \
  --json
```

---

## Assign Issue

**CLI alternative:** `linear issue update ID --assignee me|USER_ID --yes` — get `USER_ID` from
`linear users list --limit 50 --fields id,name,email --data-only`.

Assigns an issue to a user.

```bash
cat > /tmp/assign.graphql << 'EOF'
mutation AssignIssue($issueId: String!, $assigneeId: String!) {
  issueUpdate(id: $issueId, input: { assigneeId: $assigneeId }) {
    success
    issue { identifier assignee { name } }
  }
}
EOF

linear gql --query /tmp/assign.graphql \
  --vars '{"issueId":"UUID","assigneeId":"USER-UUID"}' \
  --yes --json
```

---

## Bulk Query IDs

**Mostly obsolete — prefer the dedicated commands.** Every id these queries used to be needed for now
has an enumerating command with `--fields`, `--limit`, and a `--quiet` mode that prints bare ids:

| You need | Use |
|----------|-----|
| Current user id | `linear me --json \| jq -r '.viewer.id'` |
| Team ids and keys | `linear teams list --fields id,key,name` |
| Issue UUID from an identifier | `linear issue view ENG-123 --json \| jq -r '.issue.id'` |
| User ids (`--assignee`) | `linear users list --limit 50 --fields id,name,email --data-only` |
| Workflow state ids (`--state-id`) | `linear states list --team KEY --limit 50 --fields id,name,type --data-only` |
| Label ids (`--label`, `--labels`) | `linear labels list --team KEY --limit 50 --fields id,name --data-only` |
| Milestone ids (`--milestone`) | `linear milestone list [--project ID\|NAME] --limit 50 --fields id,name,project --data-only` |
| Project ids | `linear projects list --fields id,name --limit 50` |

These commands cover the enumeration cases outright — do not reach for `gql` for any of them.

### Milestones across projects

`linear milestone list` no longer requires `--project`. Omit it and the command runs the root
`projectMilestones` query with no filter; pass it and the same query gets
`filter: { project: { id: { eq: <uuid> } } }`. The `Project` column is on by default so a
workspace-wide listing stays unambiguous.

```bash
linear milestone list --all --fields id,name,project --data-only
```

### More rows than one page holds

Every list command walks cursors, so `gql --paginate` is not needed to get past page one:

```bash
linear users list --all --quiet
linear labels list --team ENG --pages 3 --limit 50 --data-only
linear projects list --all --fields id,name
```

`--max-items N` caps the total, and stderr prints the `--cursor` value to resume from. `search` and
`issue comment list` are the only listings that still stop at `--limit`.

---

## Schema Introspection

This CLI has no `schema` command. Introspect through `gql`, write to a temp file, and grep it — this
works headlessly and needs no browser.

### Fields on a type

```bash
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

Omit `--json` (as above) so the output stays pretty-printed and greppable line-by-line.

### Accepted keys on a mutation input

Use this before guessing at an `input:` field name — it is the fastest way to confirm whether e.g.
`parentId` or `labelIds` exists and what type it wants.

```bash
linear gql --data-only --vars '{"name":"IssueUpdateInput"}' '
query InputFields($name: String!) {
  __type(name: $name) {
    inputFields { name type { name kind ofType { name kind } } }
  }
}' > /tmp/linear-input-IssueUpdateInput.json

grep -n '"name"' /tmp/linear-input-IssueUpdateInput.json
```

Swap `IssueUpdateInput` for `IssueCreateInput`, `AttachmentCreateInput`, `CommentCreateInput`,
`IssueRelationCreateInput`, `ProjectCreateInput`, `IssueFilter`, etc.

### Find a type by name

```bash
linear gql --data-only 'query { __schema { types { name kind } } }' > /tmp/linear-types.json
grep -n -i 'milestone' /tmp/linear-types.json
```

### Arguments a root query field accepts

```bash
linear gql --data-only --vars '{"name":"Query"}' '
query RootFields($name: String!) {
  __type(name: $name) { fields { name args { name type { name kind ofType { name } } } } }
}' > /tmp/linear-query-root.json

grep -n -A 8 '"issues"' /tmp/linear-query-root.json
```

### Enum values

```bash
linear gql --data-only --vars '{"name":"IssueRelationType"}' '
query EnumValues($name: String!) {
  __type(name: $name) { enumValues { name description } }
}'
```

---

## Reference

- [Linear GraphQL API](https://linear.app/developers/graphql)
- Schema reference: use [Schema Introspection](#schema-introspection) above — no browser required.
- [File Upload Guide](https://linear.app/developers/how-to-upload-a-file-to-linear)
