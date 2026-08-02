#!/usr/bin/env bash
#
# Live end-to-end test for the Linear CLI.
#
# THIS SCRIPT CREATES AND DELETES REAL DATA IN A REAL LINEAR WORKSPACE.
#
# Safety model
# ------------
#   * Every object it creates is titled with a unique run tag: "[e2e <RUN_ID>]".
#     RUN_ID is derived from the wall clock and this process's PID, so two runs
#     can never collide and no pre-existing object can ever match it.
#   * Every created id is appended to a tracking array as it is created. An EXIT
#     trap walks that array in reverse (dependency) order and deletes everything,
#     on success, on failure, and on Ctrl-C.
#   * After cleanup the run id is queried again. Anything still present is
#     reported loudly with a copy-pasteable delete command. The script never
#     claims a clean workspace it could not prove.
#   * Nothing that does not carry this run's own id is ever touched. There is no
#     "delete everything matching e2e" path anywhere in this file.
#   * The first mutation is gated behind an interactive "yes" (or --yes).
#
# Usage:
#   ./scripts/e2e.sh --team ENG
#   ./scripts/e2e.sh --team ENG --dry-run      # read-only paths only
#   ./scripts/e2e.sh --team ENG --yes          # non-interactive
#   ./scripts/e2e.sh --team ENG --keep         # leave created objects behind
#   ./scripts/e2e.sh --team ENG --verbose      # echo every CLI invocation
#
# See scripts/README-e2e.md for the full case list and the --allow-pr caveat.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BIN="${LINEAR_BIN:-$REPO_DIR/zig-out/bin/linear}"

# A syntactically valid uuid that cannot exist. Used as the target of the
# "mutation is refused without --yes" probes: if a guard ever regresses, the
# mutation that escapes hits nothing instead of hitting real data.
SENTINEL_UUID="00000000-0000-4000-8000-000000000000"

# A team key that cannot exist, used as the deliberately-bogus id in the bulk
# partial-failure case. It can never resolve to a real issue.
BOGUS_IDENTIFIER="E2ENOPE-999999"

# Every workflow state type, so verification queries cannot hide an object
# behind the CLI's default "exclude completed/canceled" filter.
ALL_STATE_TYPES="triage,backlog,unstarted,started,completed,canceled"

# Markers embedded in long-form bodies so round trips can be asserted.
DESC_FILE_MARKER="E2E_DESCRIPTION_FROM_FILE"
DESC_STDIN_MARKER="E2E_DESCRIPTION_FROM_STDIN"
CONTENT_MARKER="E2E_PROJECT_CONTENT_MARKER"
COMMENT_LINE_ONE="E2E_BODY_LINE_ONE"
COMMENT_LINE_TWO="E2E_BODY_LINE_TWO"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

TEAM=""
DRY_RUN=0
KEEP=0
VERBOSE=0
ASSUME_YES=0
ALLOW_PR=0

usage() {
	cat <<'EOF'
Usage: ./scripts/e2e.sh --team <TEAM_KEY> [options]

Required:
  --team KEY      Linear team key or id. Never inferred, never defaulted.

Options:
  --dry-run       Exercise only non-mutating paths. Creates nothing.
  --keep          Skip cleanup so created objects can be inspected.
  --verbose       Echo every CLI invocation and a preview of its output.
  --yes           Skip the interactive confirmation (for non-interactive runs).
  --allow-PR      (spelled --allow-pr) Include 'issue pr'. Off by default: it
                  creates a real, externally visible pull request.
  --help          Show this message.

Environment:
  LINEAR_BIN      Override the binary under test (default: ./zig-out/bin/linear)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--team)
		[ $# -ge 2 ] || {
			printf 'e2e: --team needs a value\n' >&2
			exit 2
		}
		TEAM="$2"
		shift 2
		;;
	--team=*)
		TEAM="${1#--team=}"
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--keep)
		KEEP=1
		shift
		;;
	--verbose | -v)
		VERBOSE=1
		shift
		;;
	--yes)
		ASSUME_YES=1
		shift
		;;
	--allow-pr)
		ALLOW_PR=1
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		printf 'e2e: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

# The team is the blast radius. Refuse to guess it, and refuse to inherit
# config.default_team_id: an operator who forgets the flag must be told, not
# silently pointed at whatever team their config happens to name.
if [ -z "$TEAM" ]; then
	printf 'e2e: --team <TEAM_KEY> is required; this script will not fall back to a configured default\n' >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Run identity and scratch space
# ---------------------------------------------------------------------------

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
TAG="[e2e $RUN_ID]"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/linear-e2e.XXXXXX")"
CMD_LOG="$SCRATCH/commands.log"
: >"$CMD_LOG"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_CASES=""

if [ -t 1 ]; then
	C_PASS=$'\033[32m'
	C_FAIL=$'\033[31m'
	C_SKIP=$'\033[33m'
	C_OFF=$'\033[0m'
else
	C_PASS=""
	C_FAIL=""
	C_SKIP=""
	C_OFF=""
fi

# Scrub anything shaped like a Linear API key out of captured output before it
# is ever printed. Nothing in this script should surface a key, and a defensive
# filter is cheaper than auditing every diagnostic path.
redact() {
	sed -E 's/lin_api_[A-Za-z0-9_-]+/lin_api_<redacted>/g'
}

preview() {
	if [ ! -s "$1" ]; then
		printf '(empty)'
		return 0
	fi
	head -c 500 "$1" | redact | tr '\n\t' '  '
}

ok() {
	PASS_COUNT=$((PASS_COUNT + 1))
	printf '%sPASS%s  %s\n' "$C_PASS" "$C_OFF" "$1"
}

# bad <case name> <newline-separated problem list>
bad() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	FAILED_CASES="$FAILED_CASES$1"$'\n'
	printf '%sFAIL%s  %s\n' "$C_FAIL" "$C_OFF" "$1"
	printf '%s\n' "$2" | while IFS= read -r line; do
		[ -n "$line" ] && printf '        %s\n' "$line"
	done
	printf '        command: %s\n' "$LAST_CMD"
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	printf '%sSKIP%s  %s (%s)\n' "$C_SKIP" "$C_OFF" "$1" "$2"
}

note() {
	printf '      %s\n' "$1"
}

phase() {
	printf '\n== %s ==\n' "$1"
}

die() {
	printf '\ne2e: %s\n' "$1" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# CLI invocation
# ---------------------------------------------------------------------------

CLI_SEQ=0
LAST_OUT=""
LAST_ERR=""
LAST_RC=0
LAST_CMD=""

_cli_begin() {
	CLI_SEQ=$((CLI_SEQ + 1))
	LAST_OUT="$SCRATCH/out.$CLI_SEQ"
	LAST_ERR="$SCRATCH/err.$CLI_SEQ"
	LAST_RC=0
	LAST_CMD="linear $*"
	printf '[%s] linear %s\n' "$CLI_SEQ" "$*" >>"$CMD_LOG"
	if [ "$VERBOSE" = 1 ]; then
		printf '      > linear %s\n' "$*"
	fi
}

_cli_end() {
	if [ "$VERBOSE" = 1 ]; then
		printf '        rc=%s stdout=%s\n' "$LAST_RC" "$(preview "$LAST_OUT")"
		if [ -s "$LAST_ERR" ]; then
			printf '        stderr=%s\n' "$(preview "$LAST_ERR")"
		fi
	fi
	return 0
}

# cli <args...>
cli() {
	_cli_begin "$@"
	"$BIN" "$@" >"$LAST_OUT" 2>"$LAST_ERR" || LAST_RC=$?
	_cli_end
}

# cli_stdin <file> <args...>
cli_stdin() {
	local infile="$1"
	shift
	_cli_begin "$@"
	"$BIN" "$@" <"$infile" >"$LAST_OUT" 2>"$LAST_ERR" || LAST_RC=$?
	_cli_end
}

# cli_in <dir> <args...> -- run with a different working directory
cli_in() {
	local dir="$1"
	shift
	_cli_begin "$@"
	(cd "$dir" && "$BIN" "$@") >"$LAST_OUT" 2>"$LAST_ERR" || LAST_RC=$?
	_cli_end
}

# ---------------------------------------------------------------------------
# Assertions
#
# assert <name> <any|nonzero|N> [checks...]
#   --stdout-nonempty | --stdout-empty
#   --contains STR | --not-contains STR
#   --err-contains STR | --err-not-contains STR
#   --jq FILTER            (jq -e over stdout)
#   --matches ERE          (grep -E over stdout)
# ---------------------------------------------------------------------------

assert() {
	local name="$1"
	shift
	local want_rc="$1"
	shift
	local problems=""

	case "$want_rc" in
	any) ;;
	nonzero)
		if [ "$LAST_RC" -eq 0 ]; then
			problems="${problems}exit code: expected non-zero, actual 0"$'\n'
		fi
		;;
	*)
		if [ "$LAST_RC" -ne "$want_rc" ]; then
			problems="${problems}exit code: expected $want_rc, actual $LAST_RC"$'\n'
			problems="${problems}stderr: $(preview "$LAST_ERR")"$'\n'
		fi
		;;
	esac

	while [ $# -gt 0 ]; do
		case "$1" in
		--stdout-nonempty)
			if [ ! -s "$LAST_OUT" ]; then
				problems="${problems}stdout: expected non-empty, actual empty"$'\n'
			fi
			shift
			;;
		--stdout-empty)
			if [ -s "$LAST_OUT" ]; then
				problems="${problems}stdout: expected empty, actual $(preview "$LAST_OUT")"$'\n'
			fi
			shift
			;;
		--contains)
			if ! grep -qF -- "$2" "$LAST_OUT"; then
				problems="${problems}stdout: expected to contain [$2], actual $(preview "$LAST_OUT")"$'\n'
			fi
			shift 2
			;;
		--not-contains)
			if grep -qF -- "$2" "$LAST_OUT"; then
				problems="${problems}stdout: expected NOT to contain [$2], but it does"$'\n'
			fi
			shift 2
			;;
		--err-contains)
			if ! grep -qF -- "$2" "$LAST_ERR"; then
				problems="${problems}stderr: expected to contain [$2], actual $(preview "$LAST_ERR")"$'\n'
			fi
			shift 2
			;;
		--err-not-contains)
			if grep -qF -- "$2" "$LAST_ERR"; then
				problems="${problems}stderr: expected NOT to contain [$2], but it does"$'\n'
			fi
			shift 2
			;;
		--matches)
			if ! grep -qE -- "$2" "$LAST_OUT"; then
				problems="${problems}stdout: expected to match /$2/, actual $(preview "$LAST_OUT")"$'\n'
			fi
			shift 2
			;;
		--jq)
			if ! jq -e -- "$2" "$LAST_OUT" >/dev/null 2>&1; then
				problems="${problems}jq: filter [$2] did not hold, actual $(preview "$LAST_OUT")"$'\n'
			fi
			shift 2
			;;
		*)
			problems="${problems}internal: unknown assert check [$1]"$'\n'
			shift
			;;
		esac
	done

	if [ -z "$problems" ]; then
		ok "$name"
	else
		bad "$name" "$problems"
	fi
	return 0
}

# assert_table <name> -- the last command's stdout is table output, not JSON.
# Skipped when config.default_output=json makes every command emit JSON.
assert_table() {
	if [ "$TABLE_MODE" -ne 1 ]; then
		skip "$1" "config.default_output=json"
		return 0
	fi
	if [ ! -s "$LAST_OUT" ]; then
		skip "$1" "no rows returned, nothing to inspect"
		return 0
	fi
	case "$(head -c 1 "$LAST_OUT")" in
	'{' | '[') bad "$1" "expected: table output"$'\n'"actual:   JSON: $(preview "$LAST_OUT")" ;;
	*) ok "$1" ;;
	esac
	return 0
}

# check <name> <expected> <actual> -- plain value comparison for computed facts
check() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1" "expected: $2"$'\n'"actual:   $3"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Created-object tracking
#
# Two parallel arrays, appended in creation order. Cleanup walks them in
# reverse, which is also reverse dependency order (milestone before its
# project, children before parents).
#
# Entries the test deletes itself are tombstoned rather than removed, so index
# arithmetic stays trivial on bash 3.2 (the macOS system bash).
# ---------------------------------------------------------------------------

TRACK_KIND=()
TRACK_ID=()

CREATED_ANY=0

track() {
	TRACK_KIND[${#TRACK_KIND[@]}]="$1"
	TRACK_ID[${#TRACK_ID[@]}]="$2"
	CREATED_ANY=1
	printf 'created %s %s\n' "$1" "$2" >>"$SCRATCH/created.log"
}

untrack() {
	local i=0
	while [ "$i" -lt "${#TRACK_ID[@]}" ]; do
		if [ "${TRACK_KIND[$i]}" = "$1" ] && [ "${TRACK_ID[$i]}" = "$2" ]; then
			TRACK_KIND[i]="deleted"
			TRACK_ID[i]=""
		fi
		i=$((i + 1))
	done
}

# git worktree state, cleaned separately (it is local, not Linear)
WORKTREE_DIR=""
WORKTREE_BRANCH=""
ORIG_BRANCH=""

# ---------------------------------------------------------------------------
# Live queries used by verification
# ---------------------------------------------------------------------------

# live_issues_matching <substring> -> "IDENT<TAB>title" lines on stdout
#
# Uses `search`, which sends no includeArchived flag, so deleted (trashed)
# issues do not come back. The title filter is applied client-side because the
# server-side query also ORs in a description match.
live_issues_matching() {
	local needle="$1"
	local out="$SCRATCH/verify-issues.$CLI_SEQ.json"
	if ! "$BIN" search "$needle" --team "$TEAM" --state-type "$ALL_STATE_TYPES" \
		--limit 50 --json >"$out" 2>"$SCRATCH/verify-issues.err"; then
		printf 'QUERY_FAILED\t%s\n' "$(preview "$SCRATCH/verify-issues.err")"
		return 0
	fi
	jq -r --arg needle "$needle" '
		[ .. | objects
		  | select(has("identifier") and has("title"))
		  | select(.title | contains($needle)) ]
		| .[] | "\(.identifier)\t\(.title)"
	' "$out" 2>/dev/null || true
}

# live_projects_matching <substring> -> "ID<TAB>name" lines on stdout
# shellcheck disable=SC2329  # reached through the EXIT trap, not a direct call
live_projects_matching() {
	local needle="$1"
	local out="$SCRATCH/verify-projects.$CLI_SEQ.json"
	if ! "$BIN" projects list --team "$TEAM" --limit 100 --json \
		>"$out" 2>"$SCRATCH/verify-projects.err"; then
		printf 'QUERY_FAILED\t%s\n' "$(preview "$SCRATCH/verify-projects.err")"
		return 0
	fi
	jq -r --arg needle "$needle" '
		[ .. | objects
		  | select(has("id") and has("name"))
		  | select(.name | contains($needle)) ]
		| .[] | "\(.id)\t\(.name)"
	' "$out" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Cleanup + verification (EXIT trap)
# ---------------------------------------------------------------------------

CLEANUP_DONE=0

# shellcheck disable=SC2329  # reached through the EXIT trap, not a direct call
cleanup_git() {
	[ -n "$WORKTREE_DIR" ] || return 0
	if [ "$KEEP" -eq 1 ]; then
		printf '\n-- --keep given: leaving the git worktree in place --\n'
		note "worktree: $WORKTREE_DIR"
		note "  git -C $REPO_DIR worktree remove --force $WORKTREE_DIR"
		if [ -n "$WORKTREE_BRANCH" ] && [ "$WORKTREE_BRANCH" != "$ORIG_BRANCH" ]; then
			note "  git -C $REPO_DIR branch -D $WORKTREE_BRANCH"
		fi
		return 0
	fi
	printf '\n-- cleaning up git worktree --\n'
	if [ -d "$WORKTREE_DIR" ]; then
		if git -C "$REPO_DIR" worktree remove --force "$WORKTREE_DIR" >>"$SCRATCH/cleanup.log" 2>&1; then
			note "removed worktree $WORKTREE_DIR"
		else
			note "WARNING: could not remove worktree $WORKTREE_DIR"
			note "  git -C $REPO_DIR worktree remove --force $WORKTREE_DIR"
		fi
	fi
	git -C "$REPO_DIR" worktree prune >>"$SCRATCH/cleanup.log" 2>&1 || true

	# Only ever delete the branch `issue start` created inside the throwaway
	# worktree, and never the branch the operator was actually on.
	if [ -n "$WORKTREE_BRANCH" ] && [ "$WORKTREE_BRANCH" != "$ORIG_BRANCH" ]; then
		if git -C "$REPO_DIR" branch -D "$WORKTREE_BRANCH" >>"$SCRATCH/cleanup.log" 2>&1; then
			note "deleted branch $WORKTREE_BRANCH"
		else
			note "WARNING: could not delete branch $WORKTREE_BRANCH"
			note "  git -C $REPO_DIR branch -D $WORKTREE_BRANCH"
		fi
	fi
	WORKTREE_DIR=""
	WORKTREE_BRANCH=""
}

# shellcheck disable=SC2329  # reached through the EXIT trap, not a direct call
cleanup_created() {
	local total="${#TRACK_ID[@]}"
	local remaining=0
	local i=0
	local kind id rc

	while [ "$i" -lt "$total" ]; do
		if [ -n "${TRACK_ID[$i]}" ]; then
			remaining=$((remaining + 1))
		fi
		i=$((i + 1))
	done

	if [ "$remaining" -eq 0 ]; then
		return 0
	fi

	printf '\n-- deleting %s tracked object(s) in reverse order --\n' "$remaining"
	i="$total"
	while [ "$i" -gt 0 ]; do
		i=$((i - 1))
		id="${TRACK_ID[$i]}"
		kind="${TRACK_KIND[$i]}"
		[ -n "$id" ] || continue

		rc=0
		case "$kind" in
		issue) "$BIN" issue delete "$id" --yes --quiet >>"$SCRATCH/cleanup.log" 2>&1 || rc=$? ;;
		comment) "$BIN" issue comment delete "$id" --yes --quiet >>"$SCRATCH/cleanup.log" 2>&1 || rc=$? ;;
		milestone) "$BIN" milestone delete "$id" --yes --quiet >>"$SCRATCH/cleanup.log" 2>&1 || rc=$? ;;
		project) "$BIN" project delete "$id" --yes >>"$SCRATCH/cleanup.log" 2>&1 || rc=$? ;;
		*)
			note "WARNING: unknown tracked kind '$kind' ($id) — not deleted"
			continue
			;;
		esac

		if [ "$rc" -eq 0 ]; then
			note "deleted $kind $id"
			TRACK_ID[i]=""
		else
			note "WARNING: failed to delete $kind $id (exit $rc)"
			note "  linear $kind delete $id --yes"
		fi
	done
}

# shellcheck disable=SC2329  # reached through the EXIT trap, not a direct call
verify_cleanup() {
	if [ "$CREATED_ANY" -eq 0 ]; then
		printf '\n-- nothing was created, so there is nothing to verify --\n'
		return 0
	fi

	printf '\n-- verifying nothing from this run is left behind --\n'
	printf '   run id: %s\n' "$RUN_ID"

	# Give Linear a moment; a delete that has not propagated would otherwise
	# read as a leftover and send the operator chasing a ghost.
	sleep 2

	local leftovers=0
	local issues projects line id

	issues="$(live_issues_matching "$RUN_ID")"
	projects="$(live_projects_matching "$RUN_ID")"

	if printf '%s' "$issues" | grep -q '^QUERY_FAILED'; then
		bad "cleanup verified: issues" "the verification query itself failed, so cleanliness is UNPROVEN"$'\n'"$issues"
		leftovers=1
	elif [ -n "$issues" ]; then
		bad "cleanup verified: issues" "expected: no live issue whose title contains $RUN_ID"$'\n'"actual:   $(printf '%s' "$issues" | tr '\n' ';')"
		leftovers=1
		printf '\n   LEFTOVER ISSUES — delete with:\n'
		printf '%s\n' "$issues" | while IFS=$'\t' read -r id line; do
			[ -n "$id" ] && printf '     %s issue delete %s --yes    # %s\n' "$BIN" "$id" "$line"
		done
	else
		ok "cleanup verified: no live issues carry run id $RUN_ID"
	fi

	if printf '%s' "$projects" | grep -q '^QUERY_FAILED'; then
		bad "cleanup verified: projects" "the verification query itself failed, so cleanliness is UNPROVEN"$'\n'"$projects"
		leftovers=1
	elif [ -n "$projects" ]; then
		bad "cleanup verified: projects" "expected: no project whose name contains $RUN_ID"$'\n'"actual:   $(printf '%s' "$projects" | tr '\n' ';')"
		leftovers=1
		printf '\n   LEFTOVER PROJECTS — delete with:\n'
		printf '%s\n' "$projects" | while IFS=$'\t' read -r id line; do
			[ -n "$id" ] || continue
			printf '     %s milestone list --project %s --quiet | %s milestone delete --bulk-stdin --yes    # %s\n' "$BIN" "$id" "$BIN" "$line"
			printf '     %s project delete %s --yes    # %s\n' "$BIN" "$id" "$line"
		done
	else
		ok "cleanup verified: no projects carry run id $RUN_ID"
	fi

	if [ "$leftovers" -ne 0 ]; then
		printf '\n   NOTE: if an identifier above was reported as successfully deleted,\n'
		printf '         check the Linear trash in the UI — deleted issues should not\n'
		# shellcheck disable=SC2016  # literal backticks, not a subshell
		printf '         come back from `search`, and one that does is itself a finding.\n'
	fi
}

# shellcheck disable=SC2329  # reached through the EXIT trap, not a direct call
print_summary() {
	printf '\n===========================================================\n'
	printf 'run id : %s\n' "$RUN_ID"
	printf 'team   : %s\n' "$TEAM"
	printf 'passed : %s\n' "$PASS_COUNT"
	printf 'failed : %s\n' "$FAIL_COUNT"
	printf 'skipped: %s\n' "$SKIP_COUNT"
	if [ -n "$FAILED_CASES" ]; then
		printf '\nfailed cases:\n'
		printf '%s' "$FAILED_CASES" | while IFS= read -r line; do
			[ -n "$line" ] && printf '  - %s\n' "$line"
		done
	fi
	printf '===========================================================\n'
}

# shellcheck disable=SC2329  # reached through the EXIT trap, not a direct call
on_exit() {
	local rc=$?
	set +e
	trap - EXIT INT TERM

	if [ "$CLEANUP_DONE" -eq 0 ]; then
		CLEANUP_DONE=1
		cleanup_git
		if [ "$KEEP" -eq 1 ]; then
			printf '\n-- --keep given: leaving created objects in place --\n'
			if [ -s "$SCRATCH/created.log" ]; then
				redact <"$SCRATCH/created.log" | while IFS= read -r line; do
					note "$line"
				done
			fi
			note "scratch dir kept: $SCRATCH"
		else
			cleanup_created
			verify_cleanup
		fi
	fi

	print_summary

	if [ "$KEEP" -eq 1 ]; then
		printf 'scratch: %s (kept)\n' "$SCRATCH"
	else
		rm -rf "$SCRATCH"
	fi

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit "$rc"
}

trap on_exit EXIT
trap 'printf "\ne2e: interrupted, cleaning up...\n" >&2; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Preflight (no API traffic)
# ---------------------------------------------------------------------------

phase "preflight"

[ -x "$BIN" ] || die "binary not found or not executable: $BIN (build it, or set LINEAR_BIN)"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

# The endpoint allowlist tests are meaningless if the escape hatch is armed.
if [ "${LINEAR_ALLOW_INSECURE_ENDPOINT:-}" = "1" ]; then
	printf 'e2e: LINEAR_ALLOW_INSECURE_ENDPOINT=1 is set; unsetting it for this run\n'
fi
unset LINEAR_ALLOW_INSECURE_ENDPOINT

cli --version
assert "preflight: --version" 0 --stdout-nonempty --not-contains "lin_api_"

printf '      binary : %s\n' "$BIN"
printf '      run id : %s\n' "$RUN_ID"
printf '      tag    : %s\n' "$TAG"

# config.default_output=json turns plain --data-only into JSON, which would
# invalidate the tab-separated shape assertions. Detect it instead of guessing.
# TABLE_MODE=0 means every command already behaves as if --json were passed:
# --data-only emits JSON instead of tab-separated rows, and the stderr
# pagination/bulk summaries are suppressed. The cases that assert those shapes
# are skipped rather than silently failing on a valid configuration.
TABLE_MODE=1
cli config show --json
if [ "$LAST_RC" -eq 0 ] && jq -e '.default_output == "json"' "$LAST_OUT" >/dev/null 2>&1; then
	TABLE_MODE=0
	printf '      NOTE: config.default_output=json — table/TSV/stderr-summary cases will be skipped\n'
fi

# ---------------------------------------------------------------------------
# Security regressions (no mutations; the endpoint cases send no request)
# ---------------------------------------------------------------------------

phase "security"

cli --endpoint http://evil.example.com me
assert "security: http:// endpoint rejected" nonzero \
	--err-contains "--endpoint rejected" \
	--err-contains "must use https" \
	--stdout-empty

cli --endpoint https://evil.example.com me
assert "security: off-allowlist https endpoint rejected" nonzero \
	--err-contains "--endpoint rejected" \
	--err-contains "endpoint host must be api.linear.app" \
	--stdout-empty

cli auth show
assert "security: auth show does not print the raw key" 0 \
	--stdout-nonempty --not-contains "lin_api_"

cli auth show --json
assert "security: auth show --json does not print the raw key" 0 \
	--stdout-nonempty --not-contains "lin_api_"

# Targets a uuid that cannot exist: if the guard regressed, the escaping
# mutation hits nothing.
cli issue update "$SENTINEL_UUID" --title "$TAG guard probe (should never be sent)"
assert "security: issue update without --yes is refused" nonzero \
	--err-contains "issue update: confirmation required"

cli gql "mutation { issueUpdate(id: \"$SENTINEL_UUID\", input: { title: \"$TAG guard probe\" }) { success } }"
assert "security: gql mutation without --yes is refused" nonzero \
	--err-contains "gql: confirmation required"

# ---------------------------------------------------------------------------
# auth
# ---------------------------------------------------------------------------

phase "auth"

cli auth status
assert "auth status" 0 --stdout-nonempty --contains "source" --not-contains "lin_api_"

cli auth status --json
assert "auth status --json" 0 \
	--jq '.key_present == true and .key_format_valid == true' \
	--not-contains "lin_api_"

cli auth test
assert "auth test" 0 --stdout-nonempty --not-contains "lin_api_"

cli auth test --json
assert "auth test --json" 0 --jq '.viewer.id | type == "string"' --not-contains "lin_api_"

# ---------------------------------------------------------------------------
# Read-only commands
# ---------------------------------------------------------------------------

phase "read-only"

cli me
assert "me" 0 --stdout-nonempty

cli me --json
assert "me --json" 0 --jq '.viewer.id | type == "string"'

cli teams list
assert "teams list" 0 --stdout-nonempty --contains "$TEAM"

cli teams list --json
assert "teams list --json" 0 --jq '[.. | objects | select(has("key"))] | length > 0'

cli labels list --team "$TEAM"
assert "labels list --team" 0

cli users list --limit 5
assert "users list --limit 5" 0 --stdout-nonempty

cli states list --team "$TEAM"
assert "states list --team" 0 --stdout-nonempty

cli projects list --team "$TEAM" --limit 5
assert "projects list --team" 0

cli issues list --team "$TEAM" --limit 3
assert "issues list --team --limit 3" 0

cli users list --include-inactive --limit 3
assert "users list --include-inactive" 0 --stdout-nonempty

cli issues list --team "$TEAM" --limit 5 --max-items 2 --sort updated:desc --human-time
assert "issues list --max-items/--sort/--human-time" 0

cli search "$RUN_ID" --team "$TEAM" --limit 5
assert "search (run id, expected to match nothing yet)" 0

cli search "$RUN_ID" --team "$TEAM" --search-fields title,description,comments --limit 5
assert "search --search-fields title,description,comments" 0

# The other half of the split: on `search`, `--fields` is a print projection
# with the same meaning it has on `issues list`.
if [ "$TABLE_MODE" -eq 1 ]; then
	cli search "$RUN_ID" --team "$TEAM" --fields identifier,title --limit 5 --data-only
	assert "search: --fields projection + --data-only" 0
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		# Like issues list, search --data-only appends the url column, so two
		# requested fields yield at least three tab-separated columns.
		NARROW="$(awk -F'\t' 'NF < 3 {c++} END {print c+0}' "$LAST_OUT")"
		check "search: --data-only rows carry fields + url column" "0" "$NARROW"
	fi
else
	skip "search: --fields projection + --data-only" "config.default_output=json"
fi

# A search-only value in `--fields` is rejected locally, naming the other flag
# instead of reading like a typo. No request is made.
cli search "$RUN_ID" --team "$TEAM" --fields comments --limit 5
assert "search: --fields comments points at --search-fields" 1 \
	--stdout-empty --err-contains "--search-fields comments"

# Pick a workflow state name for the update-by-name case. Prefer a
# non-terminal type so the issue stays visible to default-filtered queries.
STATE_NAME=""
cli states list --team "$TEAM" --fields name,type --data-only --json
if [ "$LAST_RC" -eq 0 ]; then
	STATE_NAME="$(jq -r '
		[ .nodes[]? | select(.type=="unstarted") ] +
		[ .nodes[]? | select(.type=="backlog") ] +
		[ .nodes[]? | select(.type=="triage") ]
		| .[0].name // empty
	' "$LAST_OUT" 2>/dev/null || true)"
fi
if [ -n "$STATE_NAME" ]; then
	note "state chosen for --state by-name test: $STATE_NAME"
else
	note "no unstarted/backlog/triage state found; the state-by-name case will be skipped"
fi

# A read-only `issue view` target. In a full run this is replaced by our own
# issue; in --dry-run we borrow the first identifier the team already has.
VIEW_TARGET=""
if [ "$DRY_RUN" -eq 1 ]; then
	cli issues list --team "$TEAM" --limit 1 --quiet
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		VIEW_TARGET="$(head -1 "$LAST_OUT")"
	fi
	if [ -n "$VIEW_TARGET" ]; then
		cli issue view "$VIEW_TARGET"
		assert "issue view (existing issue, read-only)" 0 --stdout-nonempty
	else
		skip "issue view" "no existing issue in team $TEAM to read"
	fi
fi

# ---------------------------------------------------------------------------
# Output modes on two list commands
# ---------------------------------------------------------------------------

phase "output modes: issues list"

cli issues list --team "$TEAM" --limit 5
assert "issues list: default output" 0
assert_table "issues list: default output is a table, not JSON"

cli issues list --team "$TEAM" --limit 5 --data-only
assert "issues list: --data-only" 0

cli issues list --team "$TEAM" --limit 5 --json
assert "issues list: --json" 0 --jq '.pageInfo | type == "object"'

cli issues list --team "$TEAM" --limit 5 --quiet
assert "issues list: --quiet" 0
if [ "$LAST_RC" -eq 0 ]; then
	BADLINES="$(grep -cvE '^[A-Za-z0-9]+-[0-9]+$' "$LAST_OUT" || true)"
	check "issues list: --quiet emits only identifiers" "0" "${BADLINES:-0}"
fi

cli issues list --team "$TEAM" --limit 5 --data-only --json
assert "issues list: --data-only --json" 0 \
	--jq '(.nodes | type == "array") and (.pageInfo | type == "object")'

if [ "$TABLE_MODE" -eq 1 ]; then
	cli issues list --team "$TEAM" --limit 5 --fields identifier,title --data-only
	assert "issues list: --fields projection + --data-only" 0
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		# issues list --data-only always appends the url as a trailing column,
		# so two requested fields yield at least three tab-separated columns.
		NARROW="$(awk -F'\t' 'NF < 3 {c++} END {print c+0}' "$LAST_OUT")"
		check "issues list: --data-only rows carry fields + url column" "0" "$NARROW"
	fi
else
	skip "issues list: --fields projection + --data-only" "config.default_output=json"
fi

cli issues list --team "$TEAM" --limit 5 --plain
assert "issues list: --plain" 0

cli issues list --team "$TEAM" --limit 5 --no-truncate
assert "issues list: --no-truncate" 0

phase "output modes: labels list"

cli labels list --team "$TEAM" --limit 5
assert "labels list: default output" 0
assert_table "labels list: default output is a table, not JSON"

cli labels list --team "$TEAM" --limit 5 --data-only
assert "labels list: --data-only" 0

cli labels list --team "$TEAM" --limit 5 --json
assert "labels list: --json" 0 --jq 'type == "object"'

cli labels list --team "$TEAM" --limit 5 --quiet
assert "labels list: --quiet" 0

cli labels list --team "$TEAM" --limit 5 --fields id,name --data-only --json
assert "labels list: --fields projection (--data-only --json)" 0 \
	--jq '.nodes | type == "array" and (all(.[]; has("id") and has("name") and (has("color") | not)))'

if [ "$TABLE_MODE" -eq 1 ]; then
	cli labels list --team "$TEAM" --limit 5 --fields id,name --data-only
	assert "labels list: --fields projection + --data-only" 0
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		WRONGCOLS="$(awk -F'\t' 'NF != 2 {c++} END {print c+0}' "$LAST_OUT")"
		check "labels list: --data-only emits exactly the projected columns" "0" "$WRONGCOLS"
	fi
else
	skip "labels list: --fields projection + --data-only" "config.default_output=json"
fi

cli labels list --team "$TEAM" --limit 5 --plain
assert "labels list: --plain" 0

cli labels list --team "$TEAM" --limit 5 --no-truncate
assert "labels list: --no-truncate" 0

# ---------------------------------------------------------------------------
# Confirmation gate — nothing above this line mutates anything
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	phase "dry run: skipping all mutating phases"
	note "no issue, comment, project, milestone, branch or PR will be created"
else
	phase "confirmation"
	cat <<EOF
About to create the following in the LIVE Linear workspace, team "$TEAM".
Every object is titled with the run tag "$TAG".

  6 issues     "$TAG lifecycle" (+ stdin-description, parent, and 3 bulk issues)
  3 comments   on the lifecycle issue (one threaded reply, one multi-line body)
  1 project    "$TAG project"
  1 milestone  "$TAG milestone" inside that project
  1 issue link relating two of the issues
  1 git worktree + branch, created locally under
               $SCRATCH  (your working tree and current branch are not touched)

All of it is deleted again on exit, including on failure or Ctrl-C, and the
run id is re-queried afterwards to prove it.
EOF
	if [ "$ALLOW_PR" -eq 1 ]; then
		# shellcheck disable=SC2016  # literal backticks, not a subshell
		printf '\n  !! --allow-pr GIVEN: a REAL pull request will be created via `gh pr create`.\n'
		printf '     It is externally visible and this script will NOT delete it.\n'
	fi
	if [ "$KEEP" -eq 1 ]; then
		printf '\n  !! --keep GIVEN: nothing will be deleted. You must clean up manually.\n'
	fi

	if [ "$ASSUME_YES" -eq 1 ]; then
		printf '\n--yes given, proceeding.\n'
	else
		if [ ! -t 0 ]; then
			die "stdin is not a terminal and --yes was not given; refusing to mutate"
		fi
		printf '\nType "yes" to proceed: '
		CONFIRM=""
		read -r CONFIRM || CONFIRM=""
		[ "$CONFIRM" = "yes" ] || die "not confirmed (got \"$CONFIRM\"); nothing was created"
	fi
fi

# ---------------------------------------------------------------------------
# Issue lifecycle
# ---------------------------------------------------------------------------

ISSUE_MAIN=""
ISSUE_LINK=""
ISSUE_PARENT=""

if [ "$DRY_RUN" -eq 0 ]; then
	phase "issue lifecycle"

	DESC_FILE="$SCRATCH/description.md"
	{
		printf '%s\n\n' "$TAG description supplied via --description-file"
		printf '%s\n' "$DESC_FILE_MARKER"
	} >"$DESC_FILE"

	cli issue create --team "$TEAM" --title "$TAG lifecycle" \
		--description-file "$DESC_FILE" --yes --quiet
	assert "issue create --description-file" 0 --matches '^[A-Za-z0-9]+-[0-9]+$'
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		ISSUE_MAIN="$(head -1 "$LAST_OUT")"
		track issue "$ISSUE_MAIN"
		note "lifecycle issue: $ISSUE_MAIN"
	else
		die "could not create the lifecycle issue; aborting before anything else is created"
	fi

	STDIN_DESC="$SCRATCH/description-stdin.md"
	{
		printf '%s\n\n' "$TAG description piped through --description-file -"
		printf '%s\n' "$DESC_STDIN_MARKER"
	} >"$STDIN_DESC"

	cli_stdin "$STDIN_DESC" issue create --team "$TEAM" --title "$TAG stdin description" \
		--description-file - --yes --quiet
	assert "issue create --description-file - (stdin)" 0 --matches '^[A-Za-z0-9]+-[0-9]+$'
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		ISSUE_LINK="$(head -1 "$LAST_OUT")"
		track issue "$ISSUE_LINK"
		note "link-target issue: $ISSUE_LINK"
	fi

	cli issue view "$ISSUE_MAIN"
	assert "issue view" 0 --stdout-nonempty --contains "$RUN_ID"

	cli issue view "$ISSUE_MAIN" --fields identifier,title,description --data-only --json
	assert "issue view: --description-file round trip" 0 \
		--jq '.description | contains("'"$DESC_FILE_MARKER"'")'

	if [ -n "$ISSUE_LINK" ]; then
		cli issue view "$ISSUE_LINK" --fields description --data-only --json
		assert "issue view: stdin description round trip" 0 \
			--jq '.description | contains("'"$DESC_STDIN_MARKER"'")'
	fi

	cli issue update "$ISSUE_MAIN" --title "$TAG lifecycle renamed" --yes --quiet
	assert "issue update --title" 0
	cli issue view "$ISSUE_MAIN" --fields title --data-only --json
	assert "issue update --title took effect" 0 --jq '.title | contains("lifecycle renamed")'

	if [ -n "$STATE_NAME" ]; then
		cli issue update "$ISSUE_MAIN" --state "$STATE_NAME" --yes --quiet
		assert "issue update --state by name" 0
		cli issue view "$ISSUE_MAIN" --fields state --data-only --json
		ACTUAL_STATE="$(jq -r '.state // empty' "$LAST_OUT" 2>/dev/null || true)"
		check "issue update --state by name took effect" "$STATE_NAME" "$ACTUAL_STATE"
	else
		skip "issue update --state by name" "no non-terminal workflow state found for team $TEAM"
	fi

	cli issue create --team "$TEAM" --title "$TAG parent" --yes --quiet
	assert "issue create (parent for --parent test)" 0
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		ISSUE_PARENT="$(head -1 "$LAST_OUT")"
		track issue "$ISSUE_PARENT"
	fi

	if [ -n "$ISSUE_PARENT" ]; then
		cli issue update "$ISSUE_MAIN" --parent "$ISSUE_PARENT" --yes --quiet
		assert "issue update --parent by identifier" 0
		cli issue view "$ISSUE_MAIN" --fields parent --data-only --json
		assert "issue update --parent took effect" 0 --jq '.parent == "'"$ISSUE_PARENT"'"'
	else
		skip "issue update --parent by identifier" "parent issue was not created"
	fi

	if [ -n "$ISSUE_LINK" ]; then
		cli issue link "$ISSUE_MAIN" --related "$ISSUE_LINK" --yes --quiet
		assert "issue link --related" 0 --stdout-nonempty
	else
		skip "issue link --related" "link target issue was not created"
	fi

	# --dry-run must validate without deleting.
	cli issue delete "$ISSUE_MAIN" --dry-run
	assert "issue delete --dry-run does not delete" 0
	cli issue view "$ISSUE_MAIN" --quiet
	assert "issue survives issue delete --dry-run" 0 --contains "$ISSUE_MAIN"

	if [ -n "$ISSUE_LINK" ]; then
		cli issue delete "$ISSUE_LINK" --yes --quiet
		assert "issue delete" 0
		if [ "$LAST_RC" -eq 0 ]; then
			untrack issue "$ISSUE_LINK"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Comments
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 0 ] && [ -n "$ISSUE_MAIN" ]; then
	phase "comments"

	COMMENT_ROOT=""
	COMMENT_REPLY=""
	COMMENT_MULTI=""

	cli issue comment "$ISSUE_MAIN" --body "$TAG comment root" --yes --quiet
	assert "issue comment create" 0 --stdout-nonempty
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		COMMENT_ROOT="$(head -1 "$LAST_OUT")"
		track comment "$COMMENT_ROOT"
	fi

	if [ -n "$COMMENT_ROOT" ]; then
		cli issue comment "$ISSUE_MAIN" --body "$TAG threaded reply" \
			--parent "$COMMENT_ROOT" --yes --quiet
		assert "issue comment --parent (threaded reply)" 0 --stdout-nonempty
		if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
			COMMENT_REPLY="$(head -1 "$LAST_OUT")"
			track comment "$COMMENT_REPLY"
		fi
	else
		skip "issue comment --parent (threaded reply)" "root comment was not created"
	fi

	# Multi-line body: the documented contract is that table and tab-separated
	# output fold it to one line, while --json returns it verbatim.
	MULTI_BODY="$SCRATCH/comment-multiline.md"
	{
		printf '%s %s\n' "$TAG" "$COMMENT_LINE_ONE"
		printf '\n'
		printf '%s\n' "$COMMENT_LINE_TWO"
	} >"$MULTI_BODY"

	cli issue comment "$ISSUE_MAIN" --body-file "$MULTI_BODY" --yes --quiet
	assert "issue comment --body-file (multi-line body)" 0 --stdout-nonempty
	if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
		COMMENT_MULTI="$(head -1 "$LAST_OUT")"
		track comment "$COMMENT_MULTI"
	fi

	cli issue comment list "$ISSUE_MAIN"
	assert "issue comment list" 0 --stdout-nonempty --contains "$RUN_ID"

	if [ -n "$COMMENT_REPLY" ] && [ -n "$COMMENT_ROOT" ]; then
		cli issue comment list "$ISSUE_MAIN" --fields id,parent --data-only --json
		assert "issue comment list: threaded reply keeps its parent" 0 \
			--jq '[.nodes[] | select(.id == "'"$COMMENT_REPLY"'") | .parent] | .[0] == "'"$COMMENT_ROOT"'"'
	fi

	if [ -n "$COMMENT_MULTI" ]; then
		# Verbatim under --data-only --json
		cli issue comment list "$ISSUE_MAIN" --fields id,body --data-only --json
		assert "comment body verbatim under --data-only --json" 0 \
			--jq '[.nodes[] | select(.id == "'"$COMMENT_MULTI"'") | .body] | .[0] | contains("\n")'

		# Verbatim under plain --json (raw response document)
		cli issue comment list "$ISSUE_MAIN" --json
		assert "comment body verbatim under --json" 0 \
			--jq '[.. | objects | select(.id? == "'"$COMMENT_MULTI"'") | .body?] | map(select(. != null)) | .[0] | contains("\n")'

		# Folded to one line in the table
		cli issue comment list "$ISSUE_MAIN" --no-truncate
		if [ "$LAST_RC" -eq 0 ]; then
			L1="$(grep -cF -- "$COMMENT_LINE_ONE" "$LAST_OUT" || true)"
			BOTH="$(grep -F -- "$COMMENT_LINE_ONE" "$LAST_OUT" | grep -cF -- "$COMMENT_LINE_TWO" || true)"
			check "comment body folded to one line in table output" "1 1" "${L1:-0} ${BOTH:-0}"
		else
			bad "comment body folded to one line in table output" "expected: exit 0"$'\n'"actual:   exit $LAST_RC"
		fi

		if [ "$TABLE_MODE" -eq 1 ]; then
			cli issue comment list "$ISSUE_MAIN" --fields id,body --data-only
			if [ "$LAST_RC" -eq 0 ]; then
				ROWS="$(grep -cF -- "$COMMENT_LINE_ONE" "$LAST_OUT" || true)"
				SAMEROW="$(grep -F -- "$COMMENT_LINE_ONE" "$LAST_OUT" | grep -cF -- "$COMMENT_LINE_TWO" || true)"
				check "comment body folded to one record in --data-only" "1 1" "${ROWS:-0} ${SAMEROW:-0}"
			else
				bad "comment body folded to one record in --data-only" "expected: exit 0"$'\n'"actual:   exit $LAST_RC"
			fi
		else
			skip "comment body folded to one record in --data-only" "config.default_output=json"
		fi

		cli issue comment update "$COMMENT_MULTI" --body "$TAG comment edited" --yes --quiet
		assert "issue comment update" 0
		cli issue comment list "$ISSUE_MAIN" --fields id,body --data-only --json
		assert "issue comment update took effect" 0 \
			--jq '[.nodes[] | select(.id == "'"$COMMENT_MULTI"'") | .body] | .[0] | contains("comment edited")'

		cli issue comment delete "$COMMENT_MULTI" --yes --quiet
		assert "issue comment delete" 0
		if [ "$LAST_RC" -eq 0 ]; then
			untrack comment "$COMMENT_MULTI"
			cli issue comment list "$ISSUE_MAIN" --quiet
			assert "deleted comment is gone from the list" 0 --not-contains "$COMMENT_MULTI"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Project + milestones
# ---------------------------------------------------------------------------

PROJECT_ID=""

if [ "$DRY_RUN" -eq 0 ]; then
	phase "project + milestones"

	cli project create --name "$TAG project" --team "$TEAM" \
		--description "$TAG throwaway project for the CLI e2e run" \
		--yes --data-only --json
	assert "project create" 0 --jq '.id | type == "string" and (length > 0)'
	if [ "$LAST_RC" -eq 0 ]; then
		PROJECT_ID="$(jq -r '.id // empty' "$LAST_OUT" 2>/dev/null || true)"
		if [ -n "$PROJECT_ID" ]; then
			track project "$PROJECT_ID"
			note "project: $PROJECT_ID"
		fi
	fi

	if [ -n "$PROJECT_ID" ]; then
		cli project view "$PROJECT_ID"
		assert "project view" 0 --stdout-nonempty --contains "$RUN_ID"

		# Project.description caps at 255 characters, so long-form text has to
		# go through --content-file. Read it back with gql, since `project view`
		# does not expose the content field.
		CONTENT_FILE="$SCRATCH/project-content.md"
		{
			printf '# %s\n\n' "$TAG project content"
			printf '%s\n\n' "$CONTENT_MARKER"
			awk 'BEGIN { while (i++ < 12) print "Long-form project content line that would not fit in the 255 character description field." }'
		} >"$CONTENT_FILE"

		cli project update "$PROJECT_ID" --content-file "$CONTENT_FILE" --yes
		assert "project update --content-file" 0

		# shellcheck disable=SC2016  # $id is a GraphQL variable, it must not expand
		cli gql 'query E2EProjectContent($id: String!) { project(id: $id) { id content } }' \
			--vars "$(printf '{"id":"%s"}' "$PROJECT_ID")" --data-only --json
		assert "project content round trip (>255 chars)" 0 \
			--jq '(.project.content | contains("'"$CONTENT_MARKER"'")) and (.project.content | length > 255)'

		cli project update "$PROJECT_ID" --name "$TAG project renamed" --yes
		assert "project update --name" 0

		if [ -n "$ISSUE_MAIN" ]; then
			cli project add-issue "$PROJECT_ID" "$ISSUE_MAIN" --yes --quiet
			assert "project add-issue" 0
			cli issue view "$ISSUE_MAIN" --fields project --data-only --json
			assert "project add-issue took effect" 0 \
				--jq '.project | contains("'"$RUN_ID"'")'

			cli project remove-issue "$PROJECT_ID" "$ISSUE_MAIN" --yes --quiet
			assert "project remove-issue" 0
		else
			skip "project add-issue / remove-issue" "no issue from this run to attach"
		fi

		MILESTONE_ID=""
		cli milestone create --project "$PROJECT_ID" --name "$TAG milestone" \
			--target-date 2030-12-31 --yes --quiet
		assert "milestone create" 0 --stdout-nonempty
		if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
			MILESTONE_ID="$(head -1 "$LAST_OUT")"
			track milestone "$MILESTONE_ID"
		fi

		if [ -n "$MILESTONE_ID" ]; then
			cli milestone list --project "$PROJECT_ID"
			assert "milestone list" 0 --stdout-nonempty --contains "$RUN_ID"

			cli milestone list --project "$PROJECT_ID" --quiet
			assert "milestone list --quiet" 0 --contains "$MILESTONE_ID"

			cli milestone view "$MILESTONE_ID" --data-only --json
			assert "milestone view" 0 --jq '.name | contains("'"$RUN_ID"'")'

			cli milestone update "$MILESTONE_ID" --name "$TAG milestone renamed" \
				--target-date 2031-01-15 --yes --quiet
			assert "milestone update" 0
			cli milestone view "$MILESTONE_ID" --data-only --json
			assert "milestone update took effect" 0 \
				--jq '(.name | contains("milestone renamed")) and (.target_date | contains("2031-01-15"))'

			cli milestone delete "$MILESTONE_ID" --yes --quiet
			assert "milestone delete" 0
			if [ "$LAST_RC" -eq 0 ]; then
				untrack milestone "$MILESTONE_ID"
			fi
		else
			skip "milestone list/view/update/delete" "milestone was not created"
		fi

		cli project delete "$PROJECT_ID" --yes
		assert "project delete" 0
		if [ "$LAST_RC" -eq 0 ]; then
			untrack project "$PROJECT_ID"
			PROJECT_ID=""
		fi
	else
		skip "project view/update/delete and all milestone cases" "project was not created"
	fi
fi

# ---------------------------------------------------------------------------
# Bulk delete
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 0 ]; then
	phase "bulk delete"

	BULK_IDS=""
	BULK_N=0
	while [ "$BULK_N" -lt 3 ]; do
		BULK_N=$((BULK_N + 1))
		cli issue create --team "$TEAM" --title "$TAG bulk $BULK_N" --yes --quiet
		if [ "$LAST_RC" -eq 0 ] && [ -s "$LAST_OUT" ]; then
			BID="$(head -1 "$LAST_OUT")"
			track issue "$BID"
			BULK_IDS="$BULK_IDS$BID"$'\n'
		else
			bad "bulk: create issue $BULK_N" "expected: exit 0 with an identifier"$'\n'"actual:   exit $LAST_RC $(preview "$LAST_OUT")"
		fi
	done
	BULK_CREATED="$(printf '%s' "$BULK_IDS" | grep -c . || true)"
	check "bulk: created 3 issues" "3" "${BULK_CREATED:-0}"

	if [ "${BULK_CREATED:-0}" -eq 3 ]; then
		BULK_LIST="$SCRATCH/bulk-ids.txt"
		printf '%s' "$BULK_IDS" >"$BULK_LIST"

		cli_stdin "$BULK_LIST" issue delete --bulk-stdin --dry-run
		assert "bulk: --bulk-stdin --dry-run sends no mutation" 0

		# All three are still there after the dry run.
		STILL=0
		while IFS= read -r BID; do
			[ -n "$BID" ] || continue
			cli issue view "$BID" --quiet
			if [ "$LAST_RC" -eq 0 ]; then
				STILL=$((STILL + 1))
			fi
		done <"$BULK_LIST"
		check "bulk: dry run left all 3 issues in place" "3" "$STILL"

		# One bogus id mixed in: the batch must keep going, delete the valid
		# ones, and still exit non-zero.
		BULK_MIXED="$SCRATCH/bulk-ids-mixed.txt"
		{
			cat "$BULK_LIST"
			printf '%s\n' "$BOGUS_IDENTIFIER"
		} >"$BULK_MIXED"

		cli_stdin "$BULK_MIXED" issue delete --bulk-stdin --yes --quiet
		assert "bulk: partial failure exits non-zero" nonzero
		if [ "$TABLE_MODE" -eq 1 ]; then
			assert "bulk: summary line reports 3 succeeded, 1 failed" nonzero \
				--err-contains "bulk complete; 3 succeeded, 1 failed"
		else
			skip "bulk: summary line reports 3 succeeded, 1 failed" "config.default_output=json suppresses it"
		fi

		while IFS= read -r BID; do
			[ -n "$BID" ] || continue
			untrack issue "$BID"
		done <"$BULK_LIST"

		sleep 1
		LEFT="$(live_issues_matching "$TAG bulk")"
		if [ -z "$LEFT" ]; then
			ok "bulk: the 3 valid ids were deleted despite the bogus one"
		else
			bad "bulk: the 3 valid ids were deleted despite the bogus one" \
				"expected: no live issue titled '$TAG bulk N'"$'\n'"actual:   $(printf '%s' "$LEFT" | tr '\n' ';')"
			# Put the survivors back under cleanup's control.
			printf '%s\n' "$LEFT" | cut -f1 >"$SCRATCH/bulk-survivors.txt"
			while IFS= read -r BID; do
				[ -n "$BID" ] || continue
				track issue "$BID"
			done <"$SCRATCH/bulk-survivors.txt"
		fi
	else
		skip "bulk delete cases" "could not create all 3 bulk issues"
	fi
fi

# ---------------------------------------------------------------------------
# Pagination (after creation, so there is enough data for a second page)
# ---------------------------------------------------------------------------

phase "pagination"

cli issues list --team "$TEAM" --limit 2 --pages 2 --json
assert "issues list --limit 2 --pages 2" 0 \
	--jq '(.pageInfo | type == "object") and (.issues.nodes | length <= 4)'

if [ "$TABLE_MODE" -eq 1 ]; then
	cli issues list --team "$TEAM" --limit 2 --pages 2
	assert "issues list pagination reports progress on stderr" 0 --err-contains "fetched"
else
	skip "issues list pagination reports progress on stderr" "config.default_output=json suppresses it"
fi

cli issues list --team "$TEAM" --limit 2 --json
if [ "$LAST_RC" -ne 0 ]; then
	skip "issues list --cursor resume" "the first page request failed"
else
	CURSOR="$(jq -r '.pageInfo.endCursor // empty' "$LAST_OUT" 2>/dev/null || true)"
	FIRST_ID="$(jq -r '[.. | objects | select(has("identifier")) | .identifier] | .[0] // empty' "$LAST_OUT" 2>/dev/null || true)"
	HAS_NEXT="$(jq -r '.pageInfo.hasNextPage // false' "$LAST_OUT" 2>/dev/null || true)"
	if [ -z "$CURSOR" ] || [ "$HAS_NEXT" != "true" ]; then
		skip "issues list --cursor resume" "team $TEAM has no second page (hasNextPage=$HAS_NEXT)"
	else
		cli issues list --team "$TEAM" --limit 2 --cursor "$CURSOR" --json
		assert "issues list --cursor resume" 0 --jq '.issues.nodes | type == "array"'
		if [ "$LAST_RC" -eq 0 ]; then
			RESUMED_ID="$(jq -r '[.. | objects | select(has("identifier")) | .identifier] | .[0] // empty' "$LAST_OUT" 2>/dev/null || true)"
			if [ -n "$RESUMED_ID" ] && [ "$RESUMED_ID" != "$FIRST_ID" ]; then
				ok "issues list --cursor actually advanced past page 1"
			else
				bad "issues list --cursor actually advanced past page 1" \
					"expected: an identifier different from page 1's first ($FIRST_ID)"$'\n'"actual:   $RESUMED_ID"
			fi
		fi
	fi
fi

# ---------------------------------------------------------------------------
# gql
# ---------------------------------------------------------------------------

phase "gql"

cli gql 'query { viewer { id } }' --data-only --json
assert "gql: plain query" 0 --jq '.viewer.id | type == "string"'

cli gql 'query { viewer { id } }' --dry-run
assert "gql: --dry-run makes no request" 0 --contains "dry run" --contains "no request made"

PAGINATE_QUERY="$SCRATCH/paginate.graphql"
cat >"$PAGINATE_QUERY" <<'EOF'
query E2EPaginate($after: String) {
  issues(first: 2, after: $after) {
    nodes { id identifier }
    pageInfo { hasNextPage endCursor }
  }
}
EOF

cli gql --query "$PAGINATE_QUERY" --paginate --max-pages 2 --data-only --json
assert "gql: --paginate walks a connection" 0 \
	--jq '(.issues.nodes | type == "array") and (.issues.pageInfo | type == "object")'

# (the "mutation without --yes is refused" case lives in the security phase)

# ---------------------------------------------------------------------------
# Git workflow
# ---------------------------------------------------------------------------

phase "git workflow"

if [ "$DRY_RUN" -eq 1 ] && [ -z "$VIEW_TARGET" ]; then
	skip "git workflow cases" "dry run with no readable issue in team $TEAM"
else
	GIT_TARGET="${ISSUE_MAIN:-$VIEW_TARGET}"

	cli issue id "$GIT_TARGET"
	assert "issue id (explicit identifier, no API call)" 0 --contains "$GIT_TARGET"

	cli issue url "$GIT_TARGET"
	assert "issue url (explicit identifier)" 0 --matches '^https://'

	cli issue title "$GIT_TARGET"
	assert "issue title (explicit identifier)" 0 --stdout-nonempty

	cli issue describe "$GIT_TARGET"
	assert "issue describe (explicit identifier)" 0 \
		--contains "Linear-issue" --contains "Linear-issue-url"

	cli issue describe "$GIT_TARGET" --references
	assert "issue describe --references" 0 --contains "References"
fi

# Branch inference and `issue start` mutate the checkout, so they run inside a
# throwaway worktree. The operator's working tree and current branch are never
# touched, which matters because this repo carries uncommitted work.
if [ "$DRY_RUN" -eq 0 ] && [ -n "$ISSUE_MAIN" ]; then
	if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		skip "issue start / branch inference" "$REPO_DIR is not a git work tree"
	else
		ORIG_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || printf '')"
		CANDIDATE_WT="$SCRATCH/worktree"
		if git -C "$REPO_DIR" worktree add --detach "$CANDIDATE_WT" HEAD >>"$SCRATCH/cleanup.log" 2>&1; then
			WORKTREE_DIR="$CANDIDATE_WT"
			note "throwaway worktree: $WORKTREE_DIR (detached from HEAD)"

			cli_in "$WORKTREE_DIR" issue start "$ISSUE_MAIN" --yes --quiet
			assert "issue start (inside throwaway worktree)" 0

			STARTED_BRANCH="$(git -C "$WORKTREE_DIR" symbolic-ref --short HEAD 2>/dev/null || printf '')"
			if [ -n "$STARTED_BRANCH" ] && [ "$STARTED_BRANCH" != "$ORIG_BRANCH" ]; then
				WORKTREE_BRANCH="$STARTED_BRANCH"
				ok "issue start checked out a new branch ($STARTED_BRANCH)"

				cli_in "$WORKTREE_DIR" issue id
				assert "issue id inferred from branch name" 0 --contains "$ISSUE_MAIN"

				cli_in "$WORKTREE_DIR" issue title
				assert "issue title inferred from branch name" 0 --contains "$RUN_ID"

				cli_in "$WORKTREE_DIR" issue url
				assert "issue url inferred from branch name" 0 --matches '^https://'

				cli_in "$WORKTREE_DIR" issue describe
				assert "issue describe inferred from branch name" 0 --contains "$ISSUE_MAIN"
			else
				bad "issue start checked out a new branch" \
					"expected: a branch other than $ORIG_BRANCH"$'\n'"actual:   ${STARTED_BRANCH:-<detached HEAD>}"
				skip "branch inference cases" "issue start did not leave a usable branch"
			fi

			if [ "$ALLOW_PR" -eq 1 ]; then
				# shellcheck disable=SC2016  # literal backticks, not a subshell
				printf '\n  !! running `issue pr` — this creates a REAL pull request\n'
				cli_in "$WORKTREE_DIR" issue pr "$ISSUE_MAIN" --draft --yes
				assert "issue pr (--allow-pr)" 0
				note "the pull request is NOT cleaned up by this script; close it yourself"
			else
				skip "issue pr" "excluded by default; it creates a real PR — pass --allow-pr"
			fi
		else
			skip "issue start / branch inference" "git worktree add failed (see $SCRATCH/cleanup.log)"
		fi
	fi
elif [ "$DRY_RUN" -eq 1 ]; then
	skip "issue start / branch inference" "dry run"
	skip "issue pr" "dry run"
fi

# ---------------------------------------------------------------------------
# Search finds what we made
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 0 ] && [ -n "$ISSUE_MAIN" ]; then
	phase "search (live data)"
	cli search "$RUN_ID" --team "$TEAM" --state-type "$ALL_STATE_TYPES" --limit 50
	assert "search finds this run's issues" 0 --contains "$ISSUE_MAIN"
fi

# ---------------------------------------------------------------------------
# Done — the EXIT trap performs cleanup, verification and the summary
# ---------------------------------------------------------------------------

phase "cleanup"
exit 0
