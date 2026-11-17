#!/bin/bash
# Real filesystem/process test. Must run in a private mount namespace as root.
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 77
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d /tmp/xray2go-uninstall-test.XXXXXX)
cleanup() {
    case "$fixture" in /tmp/xray2go-uninstall-test.*) rm -rf -- "$fixture";; esac
}
trap cleanup EXIT
mount --make-rprivate /
# Hide the host /etc with an independent tmpfs; no real service/config can be removed.
mount -t tmpfs tmpfs /etc
mkdir -p /etc/xray /etc/init.d /etc/systemd/system "$fixture/archive"
source "$repo/xray_2go.sh"
archive_root="$fixture/archive"
shortcut_path="$fixture/2go"
is_openrc() { return 0; }
service_status() { return 1; }
service_enabled() { return 1; }
service_action() { [ "$2" = stop ]; }
service_disable() { :; }
seed() {
    mkdir -p /etc/xray
    touch /etc/xray/.installed
    printf '{"inbounds":[]}' > /etc/xray/config.json
    printf '#!/bin/sh\nexec /bin/bash /etc/xray/runtime.sh "$@"\n' > "$shortcut_path"
    for s in "${SERVICES[@]}";do printf '# Managed by shadowxhero/xray-2go\n' > "$init_dir/$s";done
    printf 'unrelated service' > /etc/init.d/argox
}
seed
# Keep an actual legacy script process alive even after its script is unlinked.
printf '#!/bin/sh\nwhile true;do sleep 1;done\n' > /etc/xray/argo_sync.sh
/bin/sh /etc/xray/argo_sync.sh & legacy=$!
rm /etc/xray/argo_sync.sh
uninstall_owned
[ ! -e /etc/xray ] && [ ! -e "$shortcut_path" ]
[ -f /etc/init.d/argox ]
for s in "${SERVICES[@]}";do [ ! -e "$init_dir/$s" ];done
if kill -0 "$legacy" 2>/dev/null;then echo 'FAIL legacy process survived';exit 1;fi
wait "$legacy" 2>/dev/null || true
[ "$(find "$archive_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1 ]
compgen -G "$archive_root/xray2go-uninstalled-*/config.json" >/dev/null
echo 'UNINSTALL_SUCCESS: services removed, unrelated service preserved, deleted-script process stopped, credentials archived'
seed
service_action() { return 1; }
if uninstall_owned;then echo 'FAIL ignored service stop failure';exit 1;fi
[ -f /etc/xray/.installed ] && [ -f /etc/init.d/xray2go-sync ] && [ -f "$shortcut_path" ]
echo 'UNINSTALL_FAILURE_SAFE: failed stop retains configuration and service definition'
