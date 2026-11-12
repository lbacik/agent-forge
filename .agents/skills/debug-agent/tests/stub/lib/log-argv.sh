# Shared argv logger for the tests/stub/bin fakes. Source it, don't run it.
#
# Usage: log_argv <tool> [args...]
# Appends one `CTX=<docker-context> <tool><quoted args>` record to
# $STUB_ARGV_LOG, so the legacy-helpers test can check each helper's argv.
# Quoting is deterministic: only args holding shell-special characters are
# single-quoted (embedded single quotes are escaped).

# Note: POSIX sh has no locals, so the _la_-prefixed names below must not
# collide with the calling fake's variables.
#
# stub_fail records a loud fixture gap and exits 1. The helpers swallow
# docker stderr and exit codes on several paths (resolve.sh degrades to
# "not created" via `|| true`), so a bare stderr message would be silent;
# the test asserts $STUB_ERROR_LOG stays empty after every case instead.

stub_fail() {
  printf '%s\n' "$1" >>"${STUB_ERROR_LOG:?STUB_ERROR_LOG is not set}"
  printf '%s\n' "$1" >&2
  exit 1
}
log_argv() {
  _la_tool=$1
  shift
  _la_quoted=""
  for _la_a in "$@"; do
    case "$_la_a" in
      (*[\\\ \'\"\$\`\|\<\>\&\;\*]*|"")
        _la_q=$(printf '%s' "$_la_a" | sed "s/'/'\\\\''/g")
        _la_quoted="$_la_quoted '$_la_q'"
        ;;
      (*)
        _la_quoted="$_la_quoted $_la_a"
        ;;
    esac
  done
  printf 'CTX=%s %s%s\n' "${DOCKER_CONTEXT:-}" "$_la_tool" "$_la_quoted" >>"${STUB_ARGV_LOG:?STUB_ARGV_LOG is not set}"
}
