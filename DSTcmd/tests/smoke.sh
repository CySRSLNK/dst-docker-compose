#!/usr/bin/env bash
# Exercises management flow without root, Steam, or systemd.
set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_ROOT
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsttest.XXXXXXXX")"
cleanup() {
    local resolved parent
    resolved="$(realpath -- "$TEST_ROOT")"
    parent="$(realpath -- "${TMPDIR:-/tmp}")"
    case "$resolved" in
        "$parent"/dsttest.*) rm -rf -- "$resolved" ;;
        *) echo "Refusing cleanup outside test temporary directory." >&2 ;;
    esac
}
trap cleanup EXIT
export INSTALL_DIR="$TEST_ROOT/server" STEAMCMD_DIR="$TEST_ROOT/steam"
export DATA_DIR="$TEST_ROOT/data" BACKUP_DIR="$TEST_ROOT/backups" CLUSTER_NAME=Cluster_1
cluster="$DATA_DIR/DoNotStarveTogether/$CLUSTER_NAME"
mkdir -p "$INSTALL_DIR/bin64" "$STEAMCMD_DIR" "$cluster/Master" "$cluster/Caves" "$DATA_DIR/mods"
printf 'fake-token\n' > "$cluster/cluster_token.txt"
printf '[MISC]\nconsole_enabled = true\n' > "$cluster/cluster.ini"
touch "$cluster/Master/server.ini" "$cluster/Caves/server.ini"
printf '#!/usr/bin/env bash\nexit 0\n' > "$INSTALL_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"
chmod +x "$INSTALL_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"
printf '%s\n' '-- test mod list' > "$DATA_DIR/mods/dedicated_server_mods_setup.lua"
printf '#!/usr/bin/env bash\nexit "${STEAM_EXIT:-0}"\n' > "$STEAMCMD_DIR/steamcmd.sh"
touch "$TEST_ROOT/calls"

# Only privilege/configuration boundaries are substituted. Backup and file
# operations still use the real tools against isolated temporary directories.
source() {
    if [[ $1 != /etc/dst/dst.conf ]]; then builtin source "$@"; fi
}
flock() { return 0; }
chown() { return 0; }
runuser() { shift 3; "$@"; }
install() {
    local -a args=()
    while (($#)); do
        case "$1" in
            -o|-g|-m) shift 2 ;;
            -d) shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command mkdir -p "${args[@]}"
}
tar() {
    # The production backup includes /etc/dst, represented by this fixture.
    local -a args=()
    while (($#)); do
        if [[ $1 == -C && ${2:-} == /etc ]]; then
            args+=(-C "$TEST_ROOT/etc"); shift 2
        else
            args+=("$1"); shift
        fi
    done
    command tar "${args[@]}"
}
systemctl() {
    printf '%s\n' "$*" >> "$TEST_ROOT/calls"
    case "$1" in
        show)
            if [[ $* == *Wants* ]]; then echo 'dst@Master.service dst@Caves.service'
            elif [[ $* == *Result* ]]; then echo "${STOP_RESULT:-success}"
            elif [[ -f "$TEST_ROOT/running" ]]; then echo active
            else echo inactive
            fi ;;
        is-active) [[ -f "$TEST_ROOT/running" ]] ;;
        start) touch "$TEST_ROOT/running" ;;
        stop) rm -f -- "$TEST_ROOT/running" ;;
        *) return 0 ;;
    esac
}
export -f source flock chown runuser install tar systemctl
mkdir -p "$TEST_ROOT/etc/dst"
printf '# fixture\n' > "$TEST_ROOT/etc/dst/dst.conf"
manager() {
    sed \
        -e '/^\[\[ \$EUID -eq 0 \]\]/c\true' \
        -e 's@/run/lock/dst-manager.lock@'"$TEST_ROOT"'/manager.lock@g' \
        "$PROJECT_DIR/dst.sh" | bash -s -- "$@"
}
expect_failure() {
    if manager "$@" > "$TEST_ROOT/output" 2>&1; then
        echo "Expected failure: $*" >&2
        exit 1
    fi
}
for script in "$PROJECT_DIR"/*.sh; do bash -n "$script"; done
manager check
printf ' \n' > "$cluster/cluster_token.txt"
expect_failure check
printf 'fake-token\n' > "$cluster/cluster_token.txt"
printf '[MISC]\nconsole_enabled = false\n' > "$cluster/cluster.ini"
expect_failure start
printf '[MISC]\nconsole_enabled = true\n' > "$cluster/cluster.ini"
manager start
[[ -f "$TEST_ROOT/running" ]]
cmp "$DATA_DIR/mods/dedicated_server_mods_setup.lua" "$INSTALL_DIR/mods/dedicated_server_mods_setup.lua"
manager backup
[[ -f "$TEST_ROOT/running" ]]
shopt -s nullglob
archives=("$BACKUP_DIR"/*.tar.gz)
[[ ${#archives[@]} -eq 1 ]]
tar -tzf "${archives[0]}" | grep -q 'Cluster_1/cluster_token.txt'
manager stop
manager backup
[[ ! -f "$TEST_ROOT/running" ]]
manager start
export STEAM_EXIT=23
expect_failure update
[[ ! -f "$TEST_ROOT/running" ]]
archives=("$BACKUP_DIR"/*.tar.gz)
[[ ${#archives[@]} -eq 3 ]]
unset STEAM_EXIT
manager start
manager update
[[ -f "$TEST_ROOT/running" ]]
export STOP_RESULT=exit-code
expect_failure update
archives=("$BACKUP_DIR"/*.tar.gz)
[[ ${#archives[@]} -eq 4 ]]
echo "PASS: syntax, token checks, console checks, mod copy, stop/start, offline backup, running backup, update success/failure, unclean stop."
