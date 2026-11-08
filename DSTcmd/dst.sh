#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run with sudo dst."
source /etc/dst/dst.conf
CLUSTER_DIR="$DATA_DIR/DoNotStarveTogether/$CLUSTER_NAME"
command="${1:-help}"
case "$command" in
    help|-h|--help)
        echo "Usage: sudo dst {check|start|stop|restart|status|logs [Master|Caves]|backup|update|enable|disable}"
        exit 0 ;;
    status)
        systemctl --no-pager --full status dst.target dst@Master.service dst@Caves.service
        exit $? ;;
    logs)
        shard="${2:-Master}"
        [[ $shard == Master || $shard == Caves ]] || die "Choose Master or Caves."
        exec journalctl -u "dst@$shard.service" -n 100 -f ;;
    check|start|stop|restart|backup|update|enable|disable) ;;
    *) die "Unknown command: $command. Run sudo dst help." ;;
esac
exec 9>/run/lock/dst-manager.lock
flock -n 9 || die "Another DST operation is running."

check() {
    [[ -x "$INSTALL_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64" ]] || die "Server executable missing."
    [[ -s "$CLUSTER_DIR/cluster_token.txt" ]] || die "Fill in $CLUSTER_DIR/cluster_token.txt first."
    grep -q '[^[:space:]]' "$CLUSTER_DIR/cluster_token.txt" || die "Token must not be blank."
    [[ -f "$CLUSTER_DIR/cluster.ini" && -f "$CLUSTER_DIR/Master/server.ini" ]] || die "Cluster configuration missing."
    runuser -u dst -- test -r "$CLUSTER_DIR/cluster_token.txt" || die "The dst user cannot read the token."
    if grep -Eiq '^[[:space:]]*console_enabled[[:space:]]*=[[:space:]]*false' "$CLUSTER_DIR/cluster.ini"; then
        die "Set console_enabled = true in cluster.ini to allow graceful shutdown."
    fi
    if systemctl show dst.target -p Wants --value | grep -q 'dst@Caves.service'; then
        [[ -f "$CLUSTER_DIR/Caves/server.ini" ]] || die "Caves configuration missing."
    fi
    echo "Basic file checks passed. Network access and game login require a live start."
}
stopped() {
    local shard state
    for shard in Master Caves; do
        state="$(systemctl show "dst@$shard.service" -p ActiveState --value)"
        case "$state" in
            active|activating|deactivating|reloading) return 1 ;;
        esac
    done
}
stop() {
    local shard result
    systemctl stop dst.target dst@Master.service dst@Caves.service
    stopped || die "A shard is still running; operation aborted."
    for shard in Master Caves; do
        result="$(systemctl show "dst@$shard.service" -p Result --value)"
        [[ $result == success ]] || die "$shard did not exit cleanly ($result). Inspect its logs before continuing."
    done
}
sync_mods() {
    install -d -o dst -g dst -m 0750 "$INSTALL_DIR/mods"
    if [[ -d "$DATA_DIR/mods" ]]; then
        cp -a -- "$DATA_DIR/mods/." "$INSTALL_DIR/mods/"
        chown -R dst:dst "$INSTALL_DIR/mods"
    fi
}
start() {
    check
    sync_mods
    systemctl start dst.target
    # Starting a target again does not restart previously failed member units.
    systemctl start dst@Master.service
    if systemctl show dst.target -p Wants --value | grep -q 'dst@Caves.service'; then
        systemctl start dst@Caves.service
    fi
    echo "Start requested. Use sudo dst logs to confirm the server joined successfully."
}
backup() {
    [[ -d "$CLUSTER_DIR" ]] || die "Cluster directory missing."
    install -d -o root -g root -m 0700 "$BACKUP_DIR"
    local archive
    archive="$(mktemp "$BACKUP_DIR/dst-$(date +%Y%m%d-%H%M%S)-XXXXXX.tar.gz")"
    if ! tar -czf "$archive" -C "$DATA_DIR" DoNotStarveTogether mods -C /etc dst; then
        rm -f -- "$archive"
        die "Backup failed. No update will be performed."
    fi
    tar -tzf "$archive" >/dev/null || die "Backup verification failed."
    printf 'Backup: %s\n' "$archive"
}
case "$command" in
    check) check ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    enable) systemctl enable dst.target ;;
    disable) systemctl disable dst.target ;;
    backup|update)
        resume=false
        if systemctl is-active --quiet dst.target || ! stopped; then resume=true; fi
        stop
        backup
        if [[ $command == update ]]; then
            echo "Updating server. If this fails, services remain stopped; the backup is retained."
            runuser -u dst -- env HOME="$DATA_DIR" bash "$STEAMCMD_DIR/steamcmd.sh" \
                +force_install_dir "$INSTALL_DIR" +login anonymous +app_update 343050 validate +quit
            sync_mods
            check
        fi
        if $resume; then start; fi
        ;;
esac
