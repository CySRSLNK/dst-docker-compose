#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run with sudo bash install.sh."
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMPORT_DIR=
LOCAL_MOD=
TOKEN_FILE=
MOD_SETUP=
CAVES=true
while (($#)); do
    case "$1" in
        --import|--local-mod|--token-file|--mod-setup)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --import) IMPORT_DIR="$(realpath -e -- "$2")" ;;
                --local-mod) LOCAL_MOD="$(realpath -e -- "$2")" ;;
                --token-file) TOKEN_FILE="$(realpath -e -- "$2")" ;;
                --mod-setup) MOD_SETUP="$(realpath -e -- "$2")" ;;
            esac
            shift 2 ;;
        --no-caves) CAVES=false; shift ;;
        *) die "Usage: install.sh [--import CLUSTER_DIRECTORY] [--token-file FILE] [--mod-setup FILE] [--local-mod DIRECTORY] [--no-caves]" ;;
    esac
done
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || die "This release supports Ubuntu 22.04 only."
[[ $(uname -m) == x86_64 ]] || die "An x86_64 server is required."
[[ -d /run/systemd/system ]] || die "systemd must be running."
for file in dst.sh shard.sh dst.conf; do
    [[ -f "$SOURCE_DIR/$file" ]] || die "Missing project file: $file"
done
exec 9>/run/lock/dst-manager.lock
flock -n 9 || die "Another DST operation is running."
for shard in Master Caves; do
    state="$(systemctl show "dst@$shard.service" -p ActiveState --value 2>/dev/null || true)"
    case "$state" in
        active|activating|deactivating|reloading) die "Stop DST before installing again." ;;
    esac
done
if [[ -n $IMPORT_DIR ]]; then
    [[ -f "$IMPORT_DIR/cluster.ini" && -f "$IMPORT_DIR/Master/server.ini" ]] ||
        die "--import must point to a Cluster directory containing cluster.ini and Master/server.ini."
    if $CAVES; then
        [[ -f "$IMPORT_DIR/Caves/server.ini" ]] || die "Missing Caves/server.ini; use --no-caves for a surface-only world."
    fi
fi
[[ -z $TOKEN_FILE || -s $TOKEN_FILE ]] || die "Token file is empty."
[[ -z $MOD_SETUP || -f $MOD_SETUP ]] || die "Mod setup file missing."
if [[ -n $LOCAL_MOD ]]; then
    [[ -f "$LOCAL_MOD/modinfo.lua" ]] || die "Local mod directory must contain modinfo.lua."
    [[ $(basename -- "$LOCAL_MOD") =~ ^[a-zA-Z0-9_-]+$ ]] || die "Unsupported local mod directory name."
fi

export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update
apt-get install -y ca-certificates curl tar util-linux lib32gcc-s1 lib32stdc++6 \
    libcurl3-gnutls libcurl3-gnutls:i386
if ! id dst >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/dst --shell /usr/sbin/nologin dst
fi
[[ $(id -u dst) != 0 ]] || die "The dst account must not be root."
install -d -m 0755 /opt/dst /etc/dst
if [[ ! -f /etc/dst/dst.conf ]]; then
    install -m 0644 "$SOURCE_DIR/dst.conf" /etc/dst/dst.conf
fi
# This is administrator-owned configuration, shared by all entry points.
source /etc/dst/dst.conf
for path in "$INSTALL_DIR" "$STEAMCMD_DIR" "$DATA_DIR" "$BACKUP_DIR"; do
    [[ $path == /* && $path != / ]] || die "Configured directories must be absolute and must not be /."
done
[[ $CLUSTER_NAME =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid CLUSTER_NAME."
CLUSTER_DIR="$DATA_DIR/DoNotStarveTogether/$CLUSTER_NAME"
if [[ -n $IMPORT_DIR && -d $CLUSTER_DIR ]]; then
    die "Import destination already exists: $CLUSTER_DIR. Existing worlds are never overwritten."
fi
if [[ -n $TOKEN_FILE && -s "$CLUSTER_DIR/cluster_token.txt" ]]; then
    die "A token already exists; edit it manually to replace it."
fi
if [[ -n $MOD_SETUP && -f "$DATA_DIR/mods/dedicated_server_mods_setup.lua" ]]; then
    die "Mod setup already exists; edit the existing file instead."
fi
if [[ -n $LOCAL_MOD && -e "$DATA_DIR/mods/$(basename -- "$LOCAL_MOD")" ]]; then
    die "Local mod already exists; existing mod files are never overwritten."
fi
install -d -o dst -g dst -m 0750 "$INSTALL_DIR" "$STEAMCMD_DIR" "$DATA_DIR"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
install -d -o dst -g dst -m 0750 "$DATA_DIR/DoNotStarveTogether"

if [[ ! -f "$STEAMCMD_DIR/steamcmd.sh" ]]; then
    archive="$(mktemp /tmp/dst-steamcmd.XXXXXX.tar.gz)"
    trap 'rm -f -- "$archive"' EXIT
    curl --fail --location --retry 3 --proto '=https' \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o "$archive"
    chmod 0644 "$archive"
    runuser -u dst -- tar -xzf "$archive" -C "$STEAMCMD_DIR"
    rm -f -- "$archive"
    trap - EXIT
fi
runuser -u dst -- env HOME="$DATA_DIR" bash "$STEAMCMD_DIR/steamcmd.sh" \
    +force_install_dir "$INSTALL_DIR" +login anonymous +app_update 343050 validate +quit
[[ -x "$INSTALL_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64" ]] ||
    die "Server download did not produce the expected executable."

if [[ -n $IMPORT_DIR ]]; then
    install -d -o dst -g dst -m 0750 "$CLUSTER_DIR"
    cp -a -- "$IMPORT_DIR/." "$CLUSTER_DIR/"
    chown -R dst:dst "$CLUSTER_DIR"
else
    install -d -o dst -g dst -m 0750 "$CLUSTER_DIR/Master"
    if [[ ! -f "$CLUSTER_DIR/cluster.ini" ]]; then
        shard_key="$(cat /proc/sys/kernel/random/uuid)"
        cat > "$CLUSTER_DIR/cluster.ini" <<EOF
[GAMEPLAY]
game_mode = survival
max_players = 6
pvp = false
pause_when_empty = true

[NETWORK]
cluster_name = DST Server
cluster_description = Ubuntu dedicated server
cluster_password =

[MISC]
console_enabled = true

[SHARD]
shard_enabled = $CAVES
bind_ip = 127.0.0.1
master_ip = 127.0.0.1
master_port = 10888
cluster_key = $shard_key
EOF
    fi
    if [[ ! -f "$CLUSTER_DIR/Master/server.ini" ]]; then
        cat > "$CLUSTER_DIR/Master/server.ini" <<'EOF'
[NETWORK]
server_port = 10999
[SHARD]
is_master = true
[STEAM]
master_server_port = 27018
authentication_port = 8768
EOF
    fi
    if $CAVES; then
        install -d -o dst -g dst -m 0750 "$CLUSTER_DIR/Caves"
        if [[ ! -f "$CLUSTER_DIR/Caves/server.ini" ]]; then
            cat > "$CLUSTER_DIR/Caves/server.ini" <<'EOF'
[NETWORK]
server_port = 10998
[SHARD]
is_master = false
name = Caves
id = 2
[STEAM]
master_server_port = 27019
authentication_port = 8769
EOF
        fi
        if [[ ! -f "$CLUSTER_DIR/Caves/leveldataoverride.lua" ]]; then
            cat > "$CLUSTER_DIR/Caves/leveldataoverride.lua" <<'EOF'
return {
    override_enabled = true,
    preset = "DST_CAVE",
}
EOF
        fi
    fi
    chown -R dst:dst "$CLUSTER_DIR"
fi
if [[ -n $TOKEN_FILE ]]; then
    install -o dst -g dst -m 0600 "$TOKEN_FILE" "$CLUSTER_DIR/cluster_token.txt"
elif [[ ! -f "$CLUSTER_DIR/cluster_token.txt" ]]; then
    install -o dst -g dst -m 0600 /dev/null "$CLUSTER_DIR/cluster_token.txt"
fi
chmod 0600 "$CLUSTER_DIR/cluster_token.txt"

# Keep custom assets outside the Steam-managed tree so updates can restore them.
install -d -o dst -g dst -m 0750 "$DATA_DIR/mods"
if [[ -n $MOD_SETUP ]]; then
    install -o dst -g dst -m 0640 "$MOD_SETUP" "$DATA_DIR/mods/dedicated_server_mods_setup.lua"
elif [[ ! -f "$DATA_DIR/mods/dedicated_server_mods_setup.lua" ]]; then
    printf '%s\n' '-- Example: ServerModSetup("123456789")' > "$DATA_DIR/mods/dedicated_server_mods_setup.lua"
    chown dst:dst "$DATA_DIR/mods/dedicated_server_mods_setup.lua"
fi
if [[ -n $LOCAL_MOD ]]; then
    mod_name="$(basename -- "$LOCAL_MOD")"
    [[ ! -e "$DATA_DIR/mods/$mod_name" ]] || die "Local mod already exists: $mod_name"
    cp -a -- "$LOCAL_MOD" "$DATA_DIR/mods/$mod_name"
    chown -R dst:dst "$DATA_DIR/mods/$mod_name"
fi
install -m 0755 "$SOURCE_DIR/dst.sh" /opt/dst/dst.sh
install -m 0755 "$SOURCE_DIR/shard.sh" /opt/dst/shard.sh
ln -sfn /opt/dst/dst.sh /usr/local/bin/dst
cp -a -- "$DATA_DIR/mods/." "$INSTALL_DIR/mods/"
chown -R dst:dst "$INSTALL_DIR/mods"
cat > /etc/systemd/system/dst@.service <<'EOF'
[Unit]
Description=Don't Starve Together shard %i
Wants=network-online.target
After=network-online.target
PartOf=dst.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
User=dst
Group=dst
Environment=HOME=/var/lib/dst
RuntimeDirectory=dst-%i
RuntimeDirectoryMode=0700
ExecStart=/opt/dst/shard.sh run %i
ExecStop=/opt/dst/shard.sh stop %i ${MAINPID}
Restart=on-failure
RestartSec=15
TimeoutStopSec=120
KillSignal=SIGINT
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
EOF
wants="dst@Master.service"
if $CAVES; then wants+=" dst@Caves.service"; fi
cat > /etc/systemd/system/dst.target <<EOF
[Unit]
Description=Don't Starve Together cluster
Wants=$wants
After=network-online.target

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
printf '\nInstallation complete. No game service was started.\n'
printf 'Cluster: %s\n' "$CLUSTER_DIR"
printf 'Configure the token, then run: sudo dst check && sudo dst start\n'
printf 'Enable boot startup separately: sudo dst enable\n'
