#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
	# Overridable so the nix check can exercise the packaged binary while local
	# runs exercise the script in the working tree.
	GIT_FRANKEN="${GIT_FRANKEN:-${BATS_TEST_DIRNAME}/../git-franken}"
	export GIT_FRANKEN
	setup_repo
}

teardown() {
	teardown_repo
}

# --- reaching the manifest -------------------------------------------------

@test "edit --path prints the manifest path" {
	run franken edit --path demo
	[ "$status" -eq 0 ]
	[ "$output" = "$REPO/.git/git-franken/demo" ]
}

@test "edit --path creates a manifest with a trunk line when absent" {
	run franken edit --path demo
	[ "$status" -eq 0 ]
	[ -f "$REPO/.git/git-franken/demo" ]
	grep -q "^trunk: main$" "$REPO/.git/git-franken/demo"
}

@test "edit --path leaves an existing manifest untouched" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	local before
	before=$(cat "$REPO/.git/git-franken/demo")

	run franken edit --path demo
	[ "$status" -eq 0 ]
	[ "$(cat "$REPO/.git/git-franken/demo")" = "$before" ]
}

@test "edit opens the manifest in EDITOR" {
	fake_editor
	EDITOR="$TEST_ROOT/ed" run franken edit demo
	[ "$status" -eq 0 ]
	grep -qx "opened" "$REPO/.git/git-franken/demo"
}

# EDITOR is routinely set to a command with arguments, so it must word-split.
@test "edit honours an EDITOR that carries arguments" {
	fake_editor
	EDITOR="$TEST_ROOT/ed --flag" run franken edit demo
	[ "$status" -eq 0 ]
	grep -qx "got --flag" "$REPO/.git/git-franken/demo"
}

@test "names containing path traversal are rejected" {
	run franken edit --path "../../escape"
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid name"* ]]
	[ ! -e "$TEST_ROOT/escape" ]
}

@test "names with shell metacharacters are rejected" {
	run franken edit --path 'demo;rm -rf /'
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid name"* ]]
}

@test "edit without a name fails" {
	run franken edit
	[ "$status" -ne 0 ]
	[[ "$output" == *"missing manifest name"* ]]
}

# --- manifest parsing ------------------------------------------------------

@test "parsing ignores comments and blank lines" {
	commit_on feat-a a.txt alpha
	mkdir -p "$REPO/.git/git-franken"
	cat >"$REPO/.git/git-franken/demo" <<-EOF
		# a comment

		trunk: main
		   feat-a
		# another comment
	EOF
	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged feat-a franken/demo
}

@test "an explicit trunk overrides detection" {
	git checkout -q -b other main
	echo other >o.txt && git add o.txt && git commit -qm other
	git checkout -q main
	commit_on feat-a a.txt alpha

	mkdir -p "$REPO/.git/git-franken"
	printf 'trunk: other\nfeat-a\n' >"$REPO/.git/git-franken/demo"
	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged other franken/demo
}

@test "trunk defaults to main when the manifest omits it" {
	commit_on feat-a a.txt alpha
	mkdir -p "$REPO/.git/git-franken"
	printf 'feat-a\n' >"$REPO/.git/git-franken/demo"
	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged main franken/demo
}

# --- building --------------------------------------------------------------

@test "build merges every branch onto trunk" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	manifest demo feat-a feat-b

	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged feat-a franken/demo
	assert_merged feat-b franken/demo
	[ "$(git rev-parse --abbrev-ref HEAD)" = "franken/demo" ]
}

@test "build uses the franken namespace for the branch" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	git rev-parse --verify --quiet refs/heads/franken/demo
}

# git tries $GIT_DIR/<refname> before $GIT_DIR/refs/heads/<refname>, so storing
# manifests under $GIT_DIR/franken/ made every lookup of franken/<name> read the
# manifest and warn about a broken ref.
@test "a manifest does not shadow the branch of the same name" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	run git rev-parse franken/demo
	[ "$status" -eq 0 ]
	[[ "$output" != *"broken ref"* ]]

	run git branch --list
	[[ "$output" != *"broken ref"* ]]

	run git for-each-ref
	[[ "$output" != *"broken ref"* ]]
}

@test "build fails when a listed branch is missing" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	git branch -D feat-a
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not exist"* ]]
}

@test "build fails on a manifest listing no branches" {
	manifest demo
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"no branches"* ]]
}

@test "build rejects a branch listed twice" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a feat-a
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"twice"* ]]
}

@test "build fails on an unknown manifest" {
	run franken build ghost
	[ "$status" -ne 0 ]
	[[ "$output" == *"no manifest"* ]]
}

@test "build refuses to run with a dirty worktree" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	echo dirty >>base.txt
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"uncommitted changes"* ]]
}

@test "build discards the previous tip and rebuilds from trunk" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	manifest demo feat-a feat-b
	franken build demo
	local first
	first=$(git rev-parse franken/demo)

	manifest demo feat-a
	franken build demo
	[ "$(git rev-parse franken/demo)" != "$first" ]
	assert_merged feat-a franken/demo
	refute_merged feat-b franken/demo
}

@test "rebuilding picks up new commits on a branch" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	git checkout -q feat-a
	echo more >>a.txt && git commit -qam "feat-a: more"
	git checkout -q main

	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged feat-a franken/demo
}

@test "build reports one branch without a plural" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	run franken build demo
	[[ "$output" == *"1 branch on top of main"* ]]
}

# --- conflicts and rerere --------------------------------------------------

@test "build stops on a genuine conflict and names the file" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	manifest demo feat-a feat-b

	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"CONFLICT"* ]]
	[[ "$output" == *"shared.txt"* ]]
	[[ "$output" == *"continue demo"* ]]
}

@test "continue completes the build after a resolution" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	commit_on feat-c c.txt charlie
	manifest demo feat-a feat-b feat-c

	run franken build demo
	[ "$status" -ne 0 ]

	echo resolved >shared.txt
	git add shared.txt

	run franken continue demo
	[ "$status" -eq 0 ]
	assert_merged feat-a franken/demo
	assert_merged feat-b franken/demo
	assert_merged feat-c franken/demo
	[ "$(cat shared.txt)" = "resolved" ]
}

@test "continue refuses while paths are still unresolved" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	manifest demo feat-a feat-b
	run franken build demo
	[ "$status" -ne 0 ]

	run franken continue demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"Still unresolved"* ]]
}

@test "a rebuild replays a cached resolution instead of conflicting again" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	manifest demo feat-a feat-b

	run franken build demo
	[ "$status" -ne 0 ]
	echo resolved >shared.txt
	git add shared.txt
	run franken continue demo
	[ "$status" -eq 0 ]

	git checkout -q main
	run franken build demo
	[ "$status" -eq 0 ]
	[[ "$output" != *"CONFLICT"* ]]
	[ "$(cat shared.txt)" = "resolved" ]
	assert_merged feat-b franken/demo
}

@test "rerere replay needs no user git config" {
	# HOME is empty and GIT_CONFIG_NOSYSTEM is set, so a replay here proves the
	# tool's inlined -c flags are doing the work.
	run git config --global rerere.enabled
	[ "$status" -ne 0 ]

	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	manifest demo feat-a feat-b

	franken build demo || true
	echo resolved >shared.txt && git add shared.txt
	franken continue demo

	git checkout -q main
	run franken build demo
	[ "$status" -eq 0 ]
	[ -d "$REPO/.git/rr-cache" ]
}

# --- staleness -------------------------------------------------------------

@test "show reports up to date right after a build" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
	[[ "$output" == *"merged"* ]]
}

@test "show reports stale once a branch moves" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	git checkout -q feat-a
	echo more >>a.txt && git commit -qam "feat-a: more"
	git checkout -q main

	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"STALE"* ]]
	[[ "$output" == *"out of date"* ]]
}

@test "show flags a deleted branch as missing" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	git branch -D feat-a

	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"MISSING"* ]]
}

@test "show works before a first build" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"not built yet"* ]]
}

@test "list reports built and unbuilt manifests" {
	commit_on feat-a a.txt alpha
	manifest built feat-a
	manifest unbuilt feat-a
	franken build built

	run franken list
	[ "$status" -eq 0 ]
	[[ "$output" == *"built"*"(built)"* ]]
	[[ "$output" == *"unbuilt"*"(not built)"* ]]
}

@test "list reports the tool's footprint" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	run franken list
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing outside it"* ]]
	[[ "$output" == *"rr-cache"* ]]
	[[ "$output" == *"purge"* ]]
}

# --- dropping and purging --------------------------------------------------

@test "drop deletes the branch but keeps the manifest" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	run franken drop demo
	[ "$status" -eq 0 ]
	run ! git rev-parse --verify --quiet refs/heads/franken/demo
	[ -f "$REPO/.git/git-franken/demo" ]
}

@test "drop moves off the branch when it is checked out here" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	[ "$(git rev-parse --abbrev-ref HEAD)" = "franken/demo" ]

	run franken drop demo
	[ "$status" -eq 0 ]
	[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "purge removes every franken branch and all manifests" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	manifest one feat-a
	manifest two feat-b
	franken build one
	franken build two

	run franken purge
	[ "$status" -eq 0 ]
	[ ! -d "$REPO/.git/git-franken" ]
	[ -z "$(git for-each-ref --format='%(refname)' 'refs/heads/franken/*')" ]
}

@test "purge leaves the user's own branches alone" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	franken purge
	git rev-parse --verify --quiet refs/heads/feat-a
	git rev-parse --verify --quiet refs/heads/main
}

@test "purge does not delete the rerere cache" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	manifest demo feat-a feat-b
	franken build demo || true
	echo resolved >shared.txt && git add shared.txt
	franken continue demo
	[ -d "$REPO/.git/rr-cache" ]

	franken purge
	[ -d "$REPO/.git/rr-cache" ]
}

@test "purge --dry-run removes nothing" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	run franken purge --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing was removed"* ]]
	[ -f "$REPO/.git/git-franken/demo" ]
	git rev-parse --verify --quiet refs/heads/franken/demo
}

@test "purge moves off the branch when it is checked out here" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	[ "$(git rev-parse --abbrev-ref HEAD)" = "franken/demo" ]

	run franken purge
	[ "$status" -eq 0 ]
	[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "purge refuses rather than leave a partial mess" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	git checkout -q main
	git worktree add -q "$TEST_ROOT/wt" franken/demo

	run franken purge
	[ "$status" -ne 0 ]
	[[ "$output" == *"another worktree"* ]]
	[ -f "$REPO/.git/git-franken/demo" ]
	git rev-parse --verify --quiet refs/heads/franken/demo
}

@test "purge on an untouched repo is a no-op" {
	run franken purge
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to purge"* ]]
}

@test "purge rejects an unknown flag" {
	run franken purge --wipe-everything
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

# --- errors ----------------------------------------------------------------

@test "an unknown command is an error" {
	run franken bogus
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown command"* ]]
}

# The manifest is declarative, so mutating it through the CLI is gone for good.
@test "the removed manifest-mutating commands stay gone" {
	local cmd
	for cmd in new add rm delete; do
		run franken "$cmd" demo feat-a
		[ "$status" -ne 0 ]
		[[ "$output" == *"unknown command"* ]]
	done
}

@test "help works outside a git repository" {
	cd "$TEST_ROOT"
	run franken help
	[ "$status" -eq 0 ]
	[[ "$output" == *"integration branches"* ]]
}

@test "help lists only the commands that exist" {
	run franken help
	[ "$status" -eq 0 ]
	[[ "$output" == *"edit"* ]]
	[[ "$output" == *"build"* ]]
	[[ "$output" != *"new <name>"* ]]
	[[ "$output" != *"add <name>"* ]]
}

# --- worktrees -------------------------------------------------------------

@test "manifests are shared across worktrees" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a

	git worktree add -q "$TEST_ROOT/wt" -b scratch main
	cd "$TEST_ROOT/wt"

	run franken list
	[ "$status" -eq 0 ]
	[[ "$output" == *"demo"* ]]
}

@test "a manifest created in a linked worktree lands in the shared dir" {
	git worktree add -q "$TEST_ROOT/wt" -b scratch main
	cd "$TEST_ROOT/wt"

	run franken edit --path fromwt
	[ "$status" -eq 0 ]
	[ -f "$REPO/.git/git-franken/fromwt" ]
}

@test "build refuses when the branch is checked out in another worktree" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo
	git checkout -q main

	git worktree add -q "$TEST_ROOT/wt" franken/demo
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"checked out at"* ]]
	[[ "$output" == *"disposable"* ]]
}

@test "a resolution cached in one worktree replays in another" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	manifest demo feat-a feat-b

	franken build demo || true
	echo resolved >shared.txt && git add shared.txt
	franken continue demo
	franken drop demo

	git worktree add -q "$TEST_ROOT/wt" -b scratch main
	cd "$TEST_ROOT/wt"
	run franken build demo
	[ "$status" -eq 0 ]
	[[ "$output" != *"CONFLICT"* ]]
	[ "$(cat shared.txt)" = "resolved" ]
}

# --- push ------------------------------------------------------------------

@test "push force-updates the remote branch" {
	git init -q --bare "$TEST_ROOT/remote.git"
	git remote add origin "$TEST_ROOT/remote.git"
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	franken build demo

	run franken push demo
	[ "$status" -eq 0 ]
	git --git-dir="$TEST_ROOT/remote.git" rev-parse --verify --quiet refs/heads/franken/demo
}

@test "push fails when the branch is not built" {
	commit_on feat-a a.txt alpha
	manifest demo feat-a
	run franken push demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"not built"* ]]
}
