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

# --- manifests -------------------------------------------------------------

@test "new creates a manifest with a detected trunk" {
	run franken new demo
	[ "$status" -eq 0 ]
	[ -f "$REPO/.git/git-franken/demo" ]
	grep -q "^trunk: main$" "$REPO/.git/git-franken/demo"
}

@test "new seeds branches given as arguments" {
	commit_on feat-a a.txt alpha
	run franken new demo feat-a
	[ "$status" -eq 0 ]
	grep -qx "feat-a" "$REPO/.git/git-franken/demo"
}

@test "new refuses to clobber an existing manifest" {
	franken new demo
	run franken new demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"already exists"* ]]
}

@test "names containing path traversal are rejected" {
	run franken new "../../escape"
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid name"* ]]
	[ ! -e "$TEST_ROOT/escape" ]
}

@test "names with shell metacharacters are rejected" {
	run franken new 'demo;rm -rf /'
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid name"* ]]
}

@test "manifest parsing ignores comments and blank lines" {
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

@test "add rejects a nonexistent branch" {
	franken new demo
	run franken add demo ghost
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not exist"* ]]
}

@test "add rejects a duplicate branch" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	run franken add demo feat-a
	[ "$status" -ne 0 ]
	[[ "$output" == *"already in manifest"* ]]
}

@test "rm removes a branch from the manifest" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	franken new demo feat-a feat-b
	run franken rm demo feat-a
	[ "$status" -eq 0 ]
	run ! grep -qx "feat-a" "$REPO/.git/git-franken/demo"
	grep -qx "feat-b" "$REPO/.git/git-franken/demo"
}

@test "list reports built and unbuilt manifests" {
	commit_on feat-a a.txt alpha
	franken new built feat-a
	franken new unbuilt feat-a
	franken build built

	run franken list
	[ "$status" -eq 0 ]
	[[ "$output" == *"built"*"(built)"* ]]
	[[ "$output" == *"unbuilt"*"(not built)"* ]]
}

# --- building --------------------------------------------------------------

@test "build merges every tip onto trunk" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	franken new demo feat-a feat-b

	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged feat-a franken/demo
	assert_merged feat-b franken/demo
	[ "$(git rev-parse --abbrev-ref HEAD)" = "franken/demo" ]
}

@test "build uses the franken namespace for the branch" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo
	git rev-parse --verify --quiet refs/heads/franken/demo
}

# git tries $GIT_DIR/<refname> before $GIT_DIR/refs/heads/<refname>, so storing
# manifests under $GIT_DIR/franken/ made every lookup of franken/<name> read the
# manifest and warn about a broken ref.
@test "a manifest does not shadow the branch of the same name" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
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
	franken new demo feat-a
	git branch -D feat-a
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not exist"* ]]
}

@test "build fails on an empty manifest" {
	franken new demo
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"no branches"* ]]
}

@test "build refuses to run with a dirty worktree" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	echo dirty >>base.txt
	run franken build demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"uncommitted changes"* ]]
}

@test "build discards the previous tip and rebuilds from trunk" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	franken new demo feat-a feat-b
	franken build demo
	local first
	first=$(git rev-parse franken/demo)

	franken rm demo feat-b
	franken build demo
	[ "$(git rev-parse franken/demo)" != "$first" ]
	assert_merged feat-a franken/demo
	refute_merged feat-b franken/demo
}

@test "rebuilding picks up new commits on a tip" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo

	git checkout -q feat-a
	echo more >>a.txt && git commit -qam "feat-a: more"
	git checkout -q main

	run franken build demo
	[ "$status" -eq 0 ]
	assert_merged feat-a franken/demo
}

# --- conflicts and rerere --------------------------------------------------

@test "build stops on a genuine conflict and names the file" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	franken new demo feat-a feat-b

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
	franken new demo feat-a feat-b feat-c

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
	franken new demo feat-a feat-b
	run franken build demo
	[ "$status" -ne 0 ]

	run franken continue demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"Still unresolved"* ]]
}

@test "a rebuild replays a cached resolution instead of conflicting again" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	franken new demo feat-a feat-b

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
	franken new demo feat-a feat-b

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
	franken new demo feat-a
	franken build demo
	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"up to date"* ]]
	[[ "$output" == *"merged"* ]]
}

@test "show reports stale once a tip moves" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
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
	franken new demo feat-a
	franken build demo
	git branch -D feat-a

	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"MISSING"* ]]
}

@test "show works before a first build" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	run franken show demo
	[ "$status" -eq 0 ]
	[[ "$output" == *"not built yet"* ]]
}

# --- lifecycle -------------------------------------------------------------

@test "drop deletes the branch but keeps the manifest" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo

	run franken drop demo
	[ "$status" -eq 0 ]
	run ! git rev-parse --verify --quiet refs/heads/franken/demo
	[ -f "$REPO/.git/git-franken/demo" ]
}

@test "drop moves off the branch when it is checked out here" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo
	[ "$(git rev-parse --abbrev-ref HEAD)" = "franken/demo" ]

	run franken drop demo
	[ "$status" -eq 0 ]
	[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "delete removes both the branch and the manifest" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo

	run franken delete demo
	[ "$status" -eq 0 ]
	run ! git rev-parse --verify --quiet refs/heads/franken/demo
	[ ! -f "$REPO/.git/git-franken/demo" ]
}

# --- purge -----------------------------------------------------------------

@test "purge removes every franken branch and all manifests" {
	commit_on feat-a a.txt alpha
	commit_on feat-b b.txt bravo
	franken new one feat-a
	franken new two feat-b
	franken build one
	franken build two

	run franken purge
	[ "$status" -eq 0 ]
	[ ! -d "$REPO/.git/git-franken" ]
	[ -z "$(git for-each-ref --format='%(refname)' 'refs/heads/franken/*')" ]
}

@test "purge leaves the user's own branches alone" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo

	franken purge
	git rev-parse --verify --quiet refs/heads/feat-a
	git rev-parse --verify --quiet refs/heads/main
}

@test "purge does not delete the rerere cache" {
	commit_on feat-a shared.txt alpha
	commit_on feat-b shared.txt bravo
	franken new demo feat-a feat-b
	franken build demo || true
	echo resolved >shared.txt && git add shared.txt
	franken continue demo
	[ -d "$REPO/.git/rr-cache" ]

	franken purge
	[ -d "$REPO/.git/rr-cache" ]
}

@test "purge --dry-run removes nothing" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo

	run franken purge --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing was removed"* ]]
	[ -f "$REPO/.git/git-franken/demo" ]
	git rev-parse --verify --quiet refs/heads/franken/demo
}

@test "purge moves off the branch when it is checked out here" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo
	[ "$(git rev-parse --abbrev-ref HEAD)" = "franken/demo" ]

	run franken purge
	[ "$status" -eq 0 ]
	[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "purge refuses rather than leave a partial mess" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
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

@test "list reports the tool's footprint" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	franken build demo

	run franken list
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing outside it"* ]]
	[[ "$output" == *"rr-cache"* ]]
	[[ "$output" == *"purge"* ]]
}

# --- errors ----------------------------------------------------------------

@test "commands on an unknown manifest fail cleanly" {
	run franken build ghost
	[ "$status" -ne 0 ]
	[[ "$output" == *"no manifest"* ]]
}

@test "an unknown command is an error" {
	run franken bogus
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown command"* ]]
}

@test "help works outside a git repository" {
	cd "$TEST_ROOT"
	run franken --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"integration branches"* ]]
}

# --- worktrees -------------------------------------------------------------

@test "manifests are shared across worktrees" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a

	git worktree add -q "$TEST_ROOT/wt" -b scratch main
	cd "$TEST_ROOT/wt"

	run franken list
	[ "$status" -eq 0 ]
	[[ "$output" == *"demo"* ]]
}

@test "a build in a linked worktree writes to the shared manifest dir" {
	commit_on feat-a a.txt alpha
	git worktree add -q "$TEST_ROOT/wt" -b scratch main
	cd "$TEST_ROOT/wt"

	run franken new fromwt feat-a
	[ "$status" -eq 0 ]
	[ -f "$REPO/.git/git-franken/fromwt" ]
}

@test "build refuses when the branch is checked out in another worktree" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
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
	franken new demo feat-a feat-b

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
	franken new demo feat-a
	franken build demo

	run franken push demo
	[ "$status" -eq 0 ]
	git --git-dir="$TEST_ROOT/remote.git" rev-parse --verify --quiet refs/heads/franken/demo
}

@test "push fails when the branch is not built" {
	commit_on feat-a a.txt alpha
	franken new demo feat-a
	run franken push demo
	[ "$status" -ne 0 ]
	[[ "$output" == *"not built"* ]]
}
