#!/usr/bin/env bash

# HOME and GIT_CONFIG_NOSYSTEM are overridden so the suite never reads or
# writes the developer's real git config.
setup_repo() {
  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT
  export HOME="$TEST_ROOT/home"
  export XDG_CONFIG_HOME="$TEST_ROOT/home/.config"
  mkdir -p "$HOME"

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  REPO="$TEST_ROOT/repo"
  export REPO
  git init -q -b main "$REPO"
  cd "$REPO" || return 1

  echo base >base.txt
  git add base.txt
  git commit -qm "base"
}

teardown_repo() {
  cd / || true
  if [ -n "${TEST_ROOT:-}" ]; then
    rm -rf "$TEST_ROOT"
  fi
}

commit_on() {
  local branch=$1 file=$2 content=$3
  git checkout -q -B "$branch" main
  printf '%s\n' "$content" >"$file"
  git add "$file"
  git commit -qm "$branch: $file"
  git checkout -q main
}

franken() {
  "$GIT_FRANKEN" "$@"
}

# manifest <name> [branch...] — write a manifest the way a user would, by
# putting a file there. Pass an explicit "trunk: x" line as a branch to override.
manifest() {
  local name=$1 dir
  shift
  dir="$(git rev-parse --git-common-dir)/git-franken"
  mkdir -p "$dir"
  printf 'trunk: main\n' >"$dir/$name"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$dir/$name"
  done
}

# Writes $TEST_ROOT/ed: an editor that records whether it was invoked, and with
# what arguments, into the file it is handed.
fake_editor() {
  cat >"$TEST_ROOT/ed" <<'EOF'
#!/bin/sh
file=$1
[ "$#" -eq 2 ] && { file=$2; echo "got $1" >>"$file"; }
echo opened >>"$file"
EOF
  chmod +x "$TEST_ROOT/ed"
}

assert_merged() {
  git merge-base --is-ancestor "$1" "$2"
}

refute_merged() {
  ! git merge-base --is-ancestor "$1" "$2"
}
