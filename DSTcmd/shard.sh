#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/dst/dst.conf
export HOME="$DATA_DIR"
action="${1:-}"
shard="${2:-}"
[[ $shard == Master || $shard == Caves ]] || exit 2
fifo="/run/dst-$shard/console"
case "$action" in
    run)
        cluster="$DATA_DIR/DoNotStarveTogether/$CLUSTER_NAME"
        [[ -s "$cluster/cluster_token.txt" && -f "$cluster/cluster.ini" &&
           -f "$cluster/$shard/server.ini" ]] || {
            echo "Missing token or configuration for $shard." >&2
            exit 1
        }
        if grep -Eiq '^[[:space:]]*console_enabled[[:space:]]*=[[:space:]]*false' "$cluster/cluster.ini"; then
            echo "Set console_enabled = true in cluster.ini to allow graceful shutdown." >&2
            exit 1
        fi
        [[ ! -p $fifo ]] || rm -f -- "$fifo"
        mkfifo -m 0600 "$fifo"
        # Holding both ends open avoids EOF and allows console commands at stop.
        exec 3<> "$fifo"
        cd "$INSTALL_DIR/bin64"
        exec ./dontstarve_dedicated_server_nullrenderer_x64 \
            -console -persistent_storage_root "$DATA_DIR" \
            -conf_dir DoNotStarveTogether -cluster "$CLUSTER_NAME" \
            -shard "$shard" <&3 3>&-
        ;;
    stop)
        pid="${3:-}"
        [[ $pid =~ ^[0-9]+$ && $pid -gt 1 ]] || exit 0
        if [[ -p $fifo ]] && kill -0 "$pid" 2>/dev/null; then
            exec 3<> "$fifo"
            printf 'c_shutdown(true)\n' >&3
            exec 3>&-
            for ((attempt=0; attempt<100; attempt++)); do
                kill -0 "$pid" 2>/dev/null || exit 0
                sleep 1
            done
            echo "Save/exit timed out; systemd will send SIGINT." >&2
            exit 1
        fi
        ;;
    *) exit 2 ;;
esac
