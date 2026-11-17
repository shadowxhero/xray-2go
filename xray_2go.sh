#!/usr/bin/env bash
# Xray-2go v2.0.0 — based on eooce/xray-2go (MIT).
# 专属 Nginx、原生服务监督、原子订阅与安全迁移。2026-11-18

SCRIPT_VERSION=2.0.0
work_dir=/etc/xray
config_dir="$work_dir/config.json"
client_dir="$work_dir/url.txt"
state_file="$work_dir/state.json"
init_dir=/etc/init.d
systemd_dir=/etc/systemd/system
run_dir=/run
SELF=${BASH_SOURCE[0]}
resolve_self() {
    if [ -f "$SELF" ]; then SELF=$(readlink -f "$SELF"); return 0; fi
    local fetched
    fetched=$(mktemp /tmp/xray2go-script.XXXXXX) || return 1
    if ! curl -fsSL --retry 2 https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh -o "$fetched" || ! bash -n "$fetched" || ! grep -qx "SCRIPT_VERSION=$SCRIPT_VERSION" "$fetched"; then
        rm -f "$fetched"; red '未取得匹配版本的完整脚本，停止安装'; return 1
    fi
    SELF="$fetched"
    trap 'rm -f "$SELF"' EXIT
}
SERVICES=(xray2go-core xray2go-tunnel xray2go-sub xray2go-sync)

red() { printf '\033[1;91m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
reading() { read -r -p "$1" "$2"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_openrc() { command_exists rc-service && command_exists rc-update; }
require_root() { [ "$(id -u)" -eq 0 ] || { red '请以 root 运行'; return 1; }; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_host() { [[ "$1" =~ ^[a-zA-Z0-9._:-]+$ ]] && [[ "$1" != -* ]]; }
valid_path() { [[ "$1" =~ ^[a-zA-Z0-9_-]{8,128}$ ]]; }
random_uuid() { cat /proc/sys/kernel/random/uuid; }
random_path() { openssl rand -hex 16; }
state() { jq -er --arg k "$1" '.[$k] // empty' "$state_file"; }
state_set() {
    local k=$1 v=$2 t
    t=$(mktemp "$work_dir/.state.XXXXXX") || return 1
    jq --arg k "$k" --argjson v "$v" '.[$k]=$v' "$state_file" > "$t" && chmod 600 "$t" && mv "$t" "$state_file" || { rm -f "$t"; return 1; }
}
state_string() { state_set "$1" "$(jq -cn --arg v "$2" '$v')"; }
get_realip() {
    local ip
    ip=$(curl --noproxy '*' -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) || ip=$(curl --noproxy '*' -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null) || return 1
    valid_host "$ip" || return 1
    printf '%s\n' "$ip"
}
uri() { jq -rn --arg v "$1" '$v|@uri'; }
host_uri() { if [[ "$1" == *:* ]]; then printf '[%s]' "${1#[}" | sed 's/]]$/]/'; else printf '%s' "$1"; fi; }
normalize_host() { local h=${1#[}; printf '%s' "${h%]}"; }

# 单写者锁：锁内仅做短配置操作，不执行网络请求。进程崩溃后检查持有者再恢复。
with_lock() (
    local lock="$work_dir/.edit-lock" pid i
    for ((i=0; i<100; i++)); do
        if mkdir "$lock" 2>/dev/null; then
            printf '%s\n' "$BASHPID" > "$lock/pid"
            trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' EXIT
            "$@"; exit $?
        fi
        if [ -s "$lock/pid" ]; then
            read -r pid < "$lock/pid"
            if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
                rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true
            fi
        fi
        sleep .1
    done
    red '配置正在修改，请稍后重试'; exit 1
)

derive_public_key() {
    local private=$1 output pub
    [ -n "$private" ] || return 1
    output=$("$work_dir/xray" x25519 -i "$private") || return 1
    pub=$(printf '%s\n' "$output" | awk '/^Password|^PublicKey/ {print $NF;exit}')
    [ -n "$pub" ] && printf '%s\n' "$pub"
}
validate_xray_config() { "$work_dir/xray" run -test -c "$1" >/dev/null 2>&1; }

# 始终由真实入站和持久状态重新导出，不对 URI 做固定行号/IPv4 正则替换。
generate_subscription() { with_lock generate_subscription_unlocked; }
generate_subscription_unlocked() {
    local pub server cdn cp domain name raw xhttp id vless_raw vless_xhttp vm tmp sub a b c d
    server=$(state server) || return 1; server=$(host_uri "$server")
    cdn=$(state cdn) || return 1; cdn=$(host_uri "$cdn")
    cp=$(state cdn_port); domain=$(state tunnel_domain) || domain=''
    name=$(state name) || name=vps
    raw=$(jq -ce '.inbounds[]|select(.protocol=="vless" and .streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp"))' "$config_dir") || return 1
    xhttp=$(jq -ce '.inbounds[]|select(.protocol=="vless" and .streamSettings.security=="reality" and .streamSettings.network=="xhttp")' "$config_dir") || return 1
    a=$(uri "$name-RAW-Reality"); b=$(uri "$name-XHTTP-Reality"); c=$(uri "$name-VLESS-Argo")
    id=$(jq -er '.settings.clients[0].id' <<< "$raw") || return 1
    pub=$(derive_public_key "$(jq -r '.streamSettings.realitySettings.privateKey' <<< "$raw")") || return 1
    vless_raw="vless://$id@$server:$(jq -r .port <<< "$raw")?encryption=none&security=reality&sni=$(uri "$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<< "$raw")")&fp=chrome&pbk=$pub&type=tcp&headerType=none&flow=xtls-rprx-vision&sid=$(jq -r '.streamSettings.realitySettings.shortIds[0] // ""' <<< "$raw")#$a"
    id=$(jq -er '.settings.clients[0].id' <<< "$xhttp") || return 1
    pub=$(derive_public_key "$(jq -r '.streamSettings.realitySettings.privateKey' <<< "$xhttp")") || return 1
    vless_xhttp="vless://$id@$server:$(jq -r .port <<< "$xhttp")?encryption=none&security=reality&sni=$(uri "$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<< "$xhttp")")&fp=chrome&pbk=$pub&type=xhttp&mode=auto&sid=$(jq -r '.streamSettings.realitySettings.shortIds[0] // ""' <<< "$xhttp")#$b"
    id=$(jq -er '.inbounds[]|select(.protocol=="vless" and .streamSettings.network=="ws")|.settings.clients[0].id' "$config_dir") || return 1
    d="vless://$id@$cdn:$cp?encryption=none&security=tls&sni=$(uri "$domain")&fp=chrome&type=ws&host=$(uri "$domain")&path=%2Fvless-argo%3Fed%3D2560#$c"
    id=$(jq -er '.inbounds[]|select(.protocol=="vmess")|.settings.clients[0].id' "$config_dir") || return 1
    vm=$(jq -cn --arg name "$name-VMess-Argo" --arg address "$(state cdn)" --arg port "$cp" --arg uuid "$id" --arg domain "$domain" '{v:"2",ps:$name,add:$address,port:$port,id:$uuid,aid:"0",scy:"aes-128-gcm",net:"ws",type:"none",host:$domain,path:"/vmess-argo?ed=2560",tls:"tls",sni:$domain,alpn:"",fp:"chrome"}' | base64 | tr -d '\n') || return 1
    mkdir -p "$work_dir/public"; chmod 755 "$work_dir/public"
    tmp=$(mktemp "$work_dir/.urls.XXXXXX"); sub=$(mktemp "$work_dir/public/.sub.XXXXXX") || return 1
    printf '%s\n%s\n%s\nvmess://%s\n' "$vless_raw" "$vless_xhttp" "$d" "$vm" > "$tmp"
    base64 < "$tmp" | tr -d '\n' > "$sub" || { rm -f "$tmp" "$sub"; return 1; }
    chmod 600 "$tmp"; chmod 644 "$sub"
    # 下载只读 public/sub.txt；先生成完整文件再 rename，不暴露半条节点。
    mv "$tmp" "$client_dir"; mv "$sub" "$work_dir/public/sub.txt"
    if [ ! -L "$work_dir/sub.txt" ]; then rm -f "$work_dir/sub.txt"; fi
    ln -sfn public/sub.txt "$work_dir/sub.txt"
}
sync_subscription() { with_lock sync_subscription_unlocked; }
sync_subscription_unlocked() {
    local domain old
    if [ "$(state tunnel_mode)" = quick ]; then
        domain=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$work_dir/argo.log" 2>/dev/null | tail -1 | sed 's@https://@@')
        [ -n "$domain" ] || return 0
        old=$(state tunnel_domain || true)
        if [ "$domain" != "$old" ]; then state_string tunnel_domain "$domain" || return 1; fi
    fi
    generate_subscription_unlocked
}

port_available() {
    local p=$1 current=${2:-0}
    valid_port "$p" || { red '端口必须为 1–65535'; return 1; }
    [ "$p" = "$current" ] && return 0
    if command_exists ss; then
        ! ss -ltn | awk -v p="$p" 'NR>1 {n=split($4,a,":");if(a[n]==p)found=1} END{exit !found}'
    elif command_exists netstat; then
        ! netstat -ltn | awk -v p="$p" 'NR>2 {n=split($4,a,":");if(a[n]==p)found=1} END{exit !found}'
    else red '缺少 ss/netstat，无法安全检查端口'; return 1
    fi
}
apply_xray_config() {
    local candidate=$1 backup="$work_dir/.config.rollback"
    validate_xray_config "$candidate" || { red 'Xray 配置校验失败，原配置未改'; rm -f "$candidate"; return 1; }
    cp -p "$config_dir" "$backup"; chmod 600 "$candidate"; mv "$candidate" "$config_dir"
    if [ -f "$work_dir/.installed" ] && service_status xray2go-core && ! service_action xray2go-core restart; then
        cp -p "$backup" "$config_dir"; service_action xray2go-core restart || true
        red 'Xray 启动失败，已恢复配置'; return 1
    fi
    if ! generate_subscription_unlocked; then
        cp -p "$backup" "$config_dir"
        [ ! -f "$work_dir/.installed" ] || service_action xray2go-core restart || true
        return 1
    fi
    rm -f "$backup"
}
set_direct_port() { with_lock set_direct_port_unlocked "$@"; }
set_direct_port_unlocked() {
    local network=$1 p=$2 old candidate
    [[ "$network" == raw || "$network" == xhttp ]] || return 1
    old=$(jq -er --arg n "$network" '.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network==$n or ($n=="raw" and .streamSettings.network=="tcp")))|.port' "$config_dir") || return 1
    port_available "$p" "$old" || { red '端口无效或已占用'; return 1; }
    candidate=$(mktemp "$work_dir/.config.XXXXXX")
    jq --arg n "$network" --argjson p "$((10#$p))" '(.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network==$n or ($n=="raw" and .streamSettings.network=="tcp"))).port)=$p' "$config_dir" > "$candidate" || return 1
    apply_xray_config "$candidate"
}
set_uuid() { with_lock set_uuid_unlocked "$1"; }
set_uuid_unlocked() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    local c; c=$(mktemp "$work_dir/.config.XXXXXX")
    jq --arg id "$1" '(.inbounds[].settings.clients[]?|select(has("id")).id)=$id' "$config_dir" > "$c" && apply_xray_config "$c"
}
set_sni() { with_lock set_sni_unlocked "$@"; }
set_sni_unlocked() {
    local network=$1 host=$2 c
    [[ "$network" == raw || "$network" == xhttp ]] && valid_host "$host" || return 1
    c=$(mktemp "$work_dir/.config.XXXXXX")
    jq --arg n "$network" --arg h "$host" '(.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network==$n or ($n=="raw" and .streamSettings.network=="tcp"))).streamSettings.realitySettings) |= (del(.dest)|.target=($h+":443")|.serverNames=[$h])' "$config_dir" > "$c" && apply_xray_config "$c"
}

write_nginx_config() {
    local p path
    p=$(state subscription_port); path=$(state subscription_path)
    valid_port "$p" && valid_path "$path" || return 1
    cat > "$work_dir/nginx.conf" <<EOF
# Managed by shadowxhero/xray-2go $SCRIPT_VERSION
# 订阅服务使用单进程，避免 master 被 SIGKILL 后孤儿 worker 抢占端口。
master_process off;
worker_processes 1;
pid $work_dir/nginx.pid;
error_log stderr warn;
events { worker_connections 128; }
http {
    access_log off;
    server_tokens off;
    default_type text/plain;
    sendfile on;
    keepalive_timeout 10;
    server {
        listen 0.0.0.0:$p;
$(if [ -s /proc/net/if_inet6 ]; then printf '        listen [::]:%s ipv6only=on;\n' "$p"; fi)
        location = /$path {
            alias $work_dir/public/sub.txt;
            add_header Cache-Control "no-store";
        }
        location / { return 404; }
    }
}
EOF
    chmod 600 "$work_dir/nginx.conf"
}
service_action() {
    local name=$1 action=$2
    [[ "$name" == xray2go-* ]] || return 1
    if is_openrc; then rc-service "$name" "$action" >/dev/null 2>&1
    else systemctl "$action" "$name" >/dev/null 2>&1; fi
}
service_status() {
    if is_openrc; then rc-service "$1" status >/dev/null 2>&1
    else systemctl is-active --quiet "$1"; fi
}
service_enabled() {
    if is_openrc; then [ -L "/etc/runlevels/default/$1" ]
    else systemctl is-enabled --quiet "$1"; fi
}
service_enable() {
    if is_openrc; then rc-update add "$1" default >/dev/null 2>&1
    else systemctl enable "$1" >/dev/null 2>&1; fi
}
service_disable() {
    if is_openrc; then rc-update del "$1" default >/dev/null 2>&1 || true
    else systemctl disable "$1" >/dev/null 2>&1 || true; fi
}
write_runtime_helpers() {
    # 同步器只同步，不检查/重启 Xray、隧道或 Nginx。
    cat > "$work_dir/sync-loop.sh" <<EOF
#!/bin/sh
# Managed by shadowxhero/xray-2go
while true; do
    /bin/bash "$work_dir/runtime.sh" --sync >/dev/null 2>&1
    sleep 10
done
EOF
    cat > "$work_dir/tunnel-worker.sh" <<EOF
#!/bin/sh
# Managed by shadowxhero/xray-2go
export GOMEMLIMIT=30MiB GOGC=25
exec /bin/bash "$work_dir/runtime.sh" --tunnel-worker
EOF
    chmod 700 "$work_dir/sync-loop.sh" "$work_dir/tunnel-worker.sh"
}

write_openrc_services() {
    local name cmd args delay
    mkdir -p "$init_dir"
    for name in "${SERVICES[@]}"; do
        delay=5
        case "$name" in
            xray2go-core) cmd="$work_dir/xray"; args="run -c $config_dir" ;;
            xray2go-tunnel) cmd="$work_dir/tunnel-worker.sh"; args=''; delay=60 ;;
            xray2go-sub) cmd=$(command -v nginx); args="-c $work_dir/nginx.conf -g 'daemon off;'" ;;
            xray2go-sync) cmd="$work_dir/sync-loop.sh"; args='' ;;
        esac
        cat > "$init_dir/$name" <<EOF
#!/sbin/openrc-run
# Managed by shadowxhero/xray-2go
name="$name"
command="$cmd"
command_args="$args"
supervisor="supervise-daemon"
respawn_delay=$delay
respawn_max=0
respawn_period=0
pidfile="$run_dir/$name.pid"
export GOMEMLIMIT=48MiB
export GOGC=30
depend() { need net; }
EOF
        chmod 755 "$init_dir/$name"
    done
}
write_systemd_services() {
    local name exec delay
    mkdir -p "$systemd_dir"
    for name in "${SERVICES[@]}"; do
        delay=5
        case "$name" in
            xray2go-core) exec="$work_dir/xray run -c $config_dir" ;;
            xray2go-tunnel) exec="$work_dir/tunnel-worker.sh"; delay=60 ;;
            xray2go-sub) exec="$(command -v nginx) -c $work_dir/nginx.conf -g 'daemon off;'" ;;
            xray2go-sync) exec="$work_dir/sync-loop.sh" ;;
        esac
        cat > "$systemd_dir/$name.service" <<EOF
# Managed by shadowxhero/xray-2go
[Unit]
Description=Xray-2go $name
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=$exec
Restart=always
RestartSec=$delay
KillMode=control-group
Environment="GOMEMLIMIT=48MiB" "GOGC=30"
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$systemd_dir/$name.service"
    done
}
tunnel_worker() {
    local mode port token
    mode=$(state tunnel_mode); port=$(state argo_port)
    export GOMEMLIMIT=${ARGO_GOMEMLIMIT:-30MiB} GOGC=${ARGO_GOGC:-25}
    # 只保留当前进程日志，避免同步器拿到上次进程的旧域名。
    : > "$work_dir/argo.log"; chmod 600 "$work_dir/argo.log"
    case "$mode" in
        quick) exec "$work_dir/argo" tunnel --url "http://127.0.0.1:$port" --no-autoupdate --edge-ip-version auto --protocol http2 >> "$work_dir/argo.log" 2>&1 ;;
        json) exec "$work_dir/argo" tunnel --config "$work_dir/tunnel.yml" --no-autoupdate --edge-ip-version auto run >> "$work_dir/argo.log" 2>&1 ;;
        token) exec "$work_dir/argo" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file "$work_dir/tunnel.token" >> "$work_dir/argo.log" 2>&1 ;;
        *) return 1 ;;
    esac
}

subscription_probe() {
    local p path i probe
    p=$(state subscription_port); path=$(state subscription_path)
    probe=$(mktemp "$work_dir/.probe.XXXXXX") || return 1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$p/$path" -o "$probe" 2>/dev/null && cmp -s "$probe" "$work_dir/public/sub.txt"; then
            rm -f "$probe"; return 0
        fi
        sleep .2
    done
    rm -f "$probe"; return 1
}
set_subscription_port() { with_lock set_subscription_port_unlocked "$1"; }
set_subscription_port_unlocked() {
    local p=$1 old
    old=$(state subscription_port)
    port_available "$p" "$old" || { red '端口无效或已占用'; return 1; }
    cp -p "$state_file" "$work_dir/.state.rollback"; cp -p "$work_dir/nginx.conf" "$work_dir/.nginx.rollback"
    state_set subscription_port "$((10#$p))"; write_nginx_config
    if ! nginx -t -c "$work_dir/nginx.conf" >/dev/null 2>&1; then
        cp -p "$work_dir/.state.rollback" "$state_file"; cp -p "$work_dir/.nginx.rollback" "$work_dir/nginx.conf"; return 1
    fi
    if jq -e '.subscription_enabled' "$state_file" >/dev/null; then
        if ! service_action xray2go-sub restart || ! subscription_probe; then
            cp -p "$work_dir/.state.rollback" "$state_file"; cp -p "$work_dir/.nginx.rollback" "$work_dir/nginx.conf"
            service_action xray2go-sub restart || true; red '订阅检查失败，已恢复原端口'; return 1
        fi
    fi
    rm -f "$work_dir/.state.rollback" "$work_dir/.nginx.rollback"
    green '订阅端口已修改。NAT 机器请同时修改服务商面板的 TCP 端口映射。'
}
set_subscription_enabled() {
    if [ "$1" = true ]; then
        service_enable xray2go-sub && service_action xray2go-sub start && subscription_probe || return 1
        state_set subscription_enabled true
    else
        service_action xray2go-sub stop || return 1
        service_disable xray2go-sub; state_set subscription_enabled false
    fi
}

# 兼容旧 Caddy，只识别本脚本生成的单订阅站点。不得覆盖别人的网站。
check_caddy_owned() {
    local file=$1
    [ -f "$file" ] || return 1
    [ "$(grep -Ec '^[[:space:]]*:[0-9]+[[:space:]]*\{' "$file")" = 1 ] || return 1
    [ "$(grep -Ec '^[[:space:]]*handle /' "$file")" = 1 ] || return 1
    # 仅接受单个旧模板站点；出现其他 host/site 声明则拒绝。
    [ "$(awk '/^[^[:space:]#{}].*\{/ {n++} END{print n+0}' "$file")" = 1 ] || return 1
    grep -Eq 'root[[:space:]]+\*[[:space:]]+/etc/xray([[:space:]]|$)' "$file"
}
import_caddy_settings() {
    local file=$1 p path
    check_caddy_owned "$file" || return 1
    p=$(sed -nE 's/^[[:space:]]*:([0-9]+)[[:space:]]*\{.*/\1/p' "$file")
    path=$(awk '$1=="handle" && $2 ~ /^\// {sub(/^\//,"",$2);print $2}' "$file")
    valid_port "$p" && valid_path "$path" || return 1
    state_set subscription_port "$p"; state_string subscription_path "$path"
}
backup_installation() {
    local b="$work_dir/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$b"; chmod 700 "$work_dir/backups" "$b"
    cp -p "$config_dir" "$b/config.json"
    local f
    for f in "$state_file" "$client_dir" "$work_dir/sub.txt" "$work_dir/nginx.conf" "$work_dir/runtime.sh" "$work_dir/sync-loop.sh" "$work_dir/tunnel-worker.sh" "$work_dir/tunnel.token" "$work_dir/tunnel.json" "$work_dir/tunnel.yml" /etc/caddy/Caddyfile; do
        [ ! -f "$f" ] || cp -pL "$f" "$b/$(basename "$f")"
    done
    local s
    for s in "${SERVICES[@]}"; do
        if service_status "$s"; then touch "$b/running-$s"; fi
        if service_enabled "$s"; then touch "$b/enabled-$s"; fi
        if [ -f "$init_dir/$s" ]; then cp -p "$init_dir/$s" "$b/old-openrc-$s"; fi
        if [ -f "$systemd_dir/$s.service" ]; then cp -p "$systemd_dir/$s.service" "$b/old-systemd-$s.service"; fi
    done
    for s in xray tunnel argo-watch caddy; do
        if service_enabled "$s"; then touch "$b/legacy-enabled-$s"; fi
        if is_openrc; then rc-service "$s" status >/dev/null 2>&1 && touch "$b/legacy-running-$s" || true
        else systemctl is-active --quiet "$s" && touch "$b/legacy-running-$s" || true; fi
    done
    for f in xray tunnel argo-watch; do
        [ ! -f "$init_dir/$f" ] || cp -p "$init_dir/$f" "$b/openrc-$f"
        [ ! -f "$systemd_dir/$f.service" ] || cp -p "$systemd_dir/$f.service" "$b/systemd-$f.service"
    done
    chmod -R go-rwx "$b"; printf '%s\n' "$b" > "$work_dir/last-backup"
}
legacy_owned() {
    local file=$1
    [ -f "$file" ] && grep -Fq "$work_dir/" "$file"
}
legacy_retire() {
    local old file
    for old in argo-watch xray tunnel; do
        if is_openrc; then file="$init_dir/$old"; else file="$systemd_dir/$old.service"; fi
        legacy_owned "$file" || continue
        if is_openrc; then
            rc-service "$old" stop >/dev/null 2>&1 || true
            rc-update del "$old" >/dev/null 2>&1 || true
        else systemctl disable --now "$old" >/dev/null 2>&1 || true; fi
        case "$old" in xray) stop_owned_processes core || return 1;; tunnel) stop_owned_processes tunnel || return 1;; argo-watch) stop_legacy_sync_processes || return 1;; esac
        # 只移动已通过归属验证且已确认停止的服务文件。
        mv "$file" "$(cat "$work_dir/last-backup")/retired-$(basename "$file")"
    done
    # 老后台同步脚本即使已 unlink 也可能继续执行；匹配 argv 路径，而非宽泛 pgrep。
    stop_legacy_sync_processes
    if command_exists crontab; then
        local cron filtered
        cron=$(crontab -l 2>/dev/null) || return 0
        filtered=$(printf '%s\n' "$cron" | awk '!/\/etc\/xray\/(argo_sync|update_argo_sub)\.sh/')
        [ "$cron" = "$filtered" ] || printf '%s\n' "$filtered" | crontab -
    fi
}
owned_pids() {
    local role=$1 p arg first matched
    for p in /proc/[0-9]*; do
        [ "${p##*/}" != "$$" ] && [ "${p##*/}" != "$BASHPID" ] && [ "${p##*/}" != "$PPID" ] || continue
        [ -r "$p/cmdline" ] || continue
        first=''; matched=false
        while IFS= read -r -d '' arg; do
            if [ -z "$first" ]; then first=$arg; fi
            case "$role:$arg" in
                core:"$work_dir/xray"|tunnel:"$work_dir/argo"|tunnel:"$work_dir/tunnel-worker.sh"|sync:"$work_dir/sync-loop.sh"|legacy-sync:"$work_dir/argo_sync.sh"|legacy-sync:"$work_dir/update_argo_sub.sh") matched=true ;;
                sub:"$work_dir/nginx.conf") [ "$first" = "$(command -v nginx)" ] && matched=true ;;
                sub:"nginx: master process "*) [[ "$arg" == *"-c $work_dir/nginx.conf"* ]] && matched=true ;;
            esac
        done < "$p/cmdline"
        # 仅实际程序/解释器参数匹配，不匹配日志、grep 或任意包含字符串的 shell -c。
        case "$first" in "$work_dir/xray"|"$work_dir/argo"|"$work_dir/"*.sh|/usr/sbin/nginx|/usr/bin/nginx|/sbin/nginx|/bin/sh|/bin/bash|bash|sh|"nginx: master process "*) ;; *) matched=false;; esac
        [ "$matched" != true ] || printf '%s\n' "${p##*/}"
    done
}
stop_owned_processes() {
    local role=$1 pid i alive
    for pid in $(owned_pids "$role"); do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for i in {1..30}; do
        alive=$(owned_pids "$role"); [ -n "$alive" ] || return 0
        sleep .1
    done
    # PID 必须仍在归属扫描结果内，才允许最终 KILL。
    for pid in $(owned_pids "$role"); do kill -KILL "$pid" 2>/dev/null || true; done
    sleep .1
    [ -z "$(owned_pids "$role")" ]
}
stop_legacy_sync_processes() { stop_owned_processes legacy-sync; }
stop_owned_caddy() {
    check_caddy_owned /etc/caddy/Caddyfile || { red 'Caddy 不属于本脚本，拒绝停止'; return 1; }
    if is_openrc; then rc-service caddy stop >/dev/null 2>&1 || return 1; rc-update del caddy >/dev/null 2>&1 || true
    else systemctl disable --now caddy >/dev/null 2>&1 || return 1; fi
    touch "$work_dir/.caddy-retired"
}
load_legacy_state() {
    [ -s "$state_file" ] && return 0
    (
        local final="$state_file"
        state_file=$(mktemp "$work_dir/.import-state.XXXXXX") || exit 1
        trap 'rm -f "$state_file"' EXIT
        load_legacy_state_candidate || exit 1
        mv "$state_file" "$final"
    )
}
load_legacy_state_candidate() {
    local line vm server cdn cp name domain port argo_port mode=quick token src
    line=$(grep '^vless://' "$client_dir" | head -1)
    [ -n "$line" ] || return 1
    server=${line#*@}; server=${server%%\?*}; server=${server%:*}; server=$(normalize_host "$server")
    vm=$(grep '^vmess://' "$client_dir" | head -1); vm=$(printf '%s' "${vm#vmess://}" | base64 -d) || return 1
    cdn=$(jq -er .add <<< "$vm"); cp=$(jq -er '.port|tonumber' <<< "$vm"); name=$(jq -er '.ps|sub("-Argo$";"")' <<< "$vm"); domain=$(jq -er '.host // .sni' <<< "$vm")
    argo_port=$(jq -er '.inbounds[]|select(.settings.fallbacks)|.port' "$config_dir") || return 1
    valid_host "$server" && valid_host "$cdn" && valid_port "$cp" && valid_port "$argo_port" || return 1
    jq -n --arg name "${NODE_NAME:-$name}" --arg server "$server" --arg cdn "$cdn" --argjson cp "$cp" --arg domain "$domain" --argjson ap "$argo_port" '{version:2,name:$name,server:$server,cdn:$cdn,cdn_port:$cp,subscription_port:43013,subscription_path:"temporary-import",subscription_enabled:true,tunnel_mode:"quick",tunnel_domain:$domain,argo_port:$ap}' > "$state_file"
    chmod 600 "$state_file"
    import_caddy_settings /etc/caddy/Caddyfile || { red '未识别到原订阅端口/路径，停止迁移'; return 1; }
    if is_openrc; then src="$init_dir/tunnel"; else src="$systemd_dir/tunnel.service"; fi
    if [ -f "$src" ]; then
        if grep -q -- '--token ' "$src"; then
            token=$(sed -nE 's/.*--token ([A-Za-z0-9_=.-]+).*/\1/p' "$src" | head -1)
            [ -n "$token" ] || return 1
            printf '%s' "$token" > "$work_dir/tunnel.token"; chmod 600 "$work_dir/tunnel.token"; mode=token
        elif grep -q -- '--config ' "$src"; then
            [ -s "$work_dir/tunnel.yml" ] && [ -s "$work_dir/tunnel.json" ] || return 1
            chmod 600 "$work_dir/tunnel.yml" "$work_dir/tunnel.json"; mode=json
        elif ! grep -q -- '--url ' "$src"; then red '无法识别旧隧道模式'; return 1; fi
    fi
    state_string tunnel_mode "$mode"
    if is_openrc; then rc-service caddy status >/dev/null 2>&1 || state_set subscription_enabled false
    else systemctl is-active --quiet caddy || state_set subscription_enabled false; fi
}
install_dependencies() {
    if command_exists apk; then apk add --no-cache bash jq curl unzip openssl nginx iproute2
    elif command_exists apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl unzip openssl nginx iproute2
    elif command_exists dnf; then dnf install -y jq curl unzip openssl nginx iproute
    elif command_exists yum; then yum install -y jq curl unzip openssl nginx iproute
    else red '不支持的软件包管理器'; return 1; fi
}
install_runtime_copy() {
    if [ "$SELF" != "$work_dir/runtime.sh" ]; then cp "$SELF" "$work_dir/runtime.sh"; fi
    chmod 700 "$work_dir/runtime.sh"
    cat > /usr/bin/2go <<'EOF'
#!/bin/sh
exec /bin/bash /etc/xray/runtime.sh "$@"
EOF
    chmod 755 /usr/bin/2go
}
configure_services() {
    write_runtime_helpers
    if is_openrc; then command_exists supervise-daemon || { red 'OpenRC 缺少 supervise-daemon'; return 1; }; write_openrc_services
    else write_systemd_services; systemctl daemon-reload; fi
    local s
    for s in "${SERVICES[@]}"; do
        if [ -n "${UPGRADE_BACKUP:-}" ] && { [ -f "$UPGRADE_BACKUP/old-openrc-$s" ] || [ -f "$UPGRADE_BACKUP/old-systemd-$s.service" ]; }; then
            if [ -f "$UPGRADE_BACKUP/enabled-$s" ]; then service_enable "$s"; else service_disable "$s"; fi
        elif [ "$s" = xray2go-sub ] && ! jq -e .subscription_enabled "$state_file" >/dev/null; then service_disable "$s"
        else service_enable "$s" || return 1; fi
    done
}
start_services() {
    local s old action
    for s in "${SERVICES[@]}"; do
        if [ "$s" = xray2go-sub ] && ! jq -e .subscription_enabled "$state_file" >/dev/null; then continue; fi
        action=start
        if [ -n "${UPGRADE_BACKUP:-}" ]; then
            if [ -f "$UPGRADE_BACKUP/old-openrc-$s" ] || [ -f "$UPGRADE_BACKUP/old-systemd-$s.service" ]; then
                [ -f "$UPGRADE_BACKUP/running-$s" ] || continue
                action=restart
            else
                case "$s" in xray2go-core) old=xray;; xray2go-tunnel) old=tunnel;; *) old='';; esac
                if [ -n "$old" ] && { [ -f "$UPGRADE_BACKUP/openrc-$old" ] || [ -f "$UPGRADE_BACKUP/systemd-$old.service" ]; }; then
                    [ -f "$UPGRADE_BACKUP/legacy-running-$old" ] || continue
                fi
            fi
        fi
        service_action "$s" "$action" || return 1
        if [ "$s" = xray2go-sub ]; then subscription_probe || return 1; fi
    done
}
rollback_upgrade() {
    local b=$1 s f
    red '迁移失败，正在恢复备份和原服务状态'
    for s in "${SERVICES[@]}"; do
        service_action "$s" stop || true
        if [ -f "$b/old-openrc-$s" ]; then cp -p "$b/old-openrc-$s" "$init_dir/$s"
        elif [ -f "$b/old-systemd-$s.service" ]; then cp -p "$b/old-systemd-$s.service" "$systemd_dir/$s.service"
        else service_disable "$s"; rm -f "$init_dir/$s" "$systemd_dir/$s.service"; fi
    done
    if [ ! -f "$b/state.json" ]; then rm -f "$work_dir/.caddy-retired"; fi
    for f in config.json state.json url.txt sub.txt nginx.conf runtime.sh sync-loop.sh tunnel-worker.sh tunnel.token tunnel.json tunnel.yml; do
        if [ -f "$b/$f" ]; then
            if [ "$f" = sub.txt ] && [ -L "$work_dir/sub.txt" ] && [ ! -f "$b/state.json" ]; then rm -f "$work_dir/sub.txt"; fi
            cp -p "$b/$f" "$work_dir/$f"
        elif [ "$f" = state.json ]; then rm -f "$state_file"; fi
    done
    for s in xray tunnel argo-watch; do
        if [ -f "$b/retired-$s" ]; then cp -p "$b/retired-$s" "$init_dir/$s"; fi
        if [ -f "$b/retired-$s.service" ]; then cp -p "$b/retired-$s.service" "$systemd_dir/$s.service"; fi
    done
    if ! is_openrc; then systemctl daemon-reload; fi
    for s in xray tunnel argo-watch caddy; do
        if [ -f "$b/legacy-enabled-$s" ]; then
            if is_openrc; then rc-update add "$s" default >/dev/null 2>&1;else systemctl enable "$s" >/dev/null 2>&1;fi
        fi
        if [ -f "$b/legacy-running-$s" ]; then
            if is_openrc; then rc-service "$s" start >/dev/null 2>&1;else systemctl start "$s" >/dev/null 2>&1;fi
        fi
    done
    for s in "${SERVICES[@]}"; do
        if [ -f "$b/enabled-$s" ]; then service_enable "$s";else service_disable "$s";fi
        if [ -f "$b/running-$s" ]; then service_action "$s" start || true; fi
    done
}
upgrade_installation() (
    set -e
    [ -s "$config_dir" ] && [ -s "$client_dir" ] || { red '未找到可迁移的 Xray-2go 安装'; return 1; }
    install_dependencies || return 1
    backup_installation || return 1
    local backup; backup=$(cat "$work_dir/last-backup")
    UPGRADE_BACKUP="$backup"
    trap 'r=$?; if [ "$r" -ne 0 ]; then rollback_upgrade "$backup"; fi' EXIT
    load_legacy_state || return 1
    [ -z "${NODE_NAME:-}" ] || state_string name "$NODE_NAME"
    # 只校正旧 RAW 入站/flow；不改 UUID、私钥、短 ID、端口和 SNI。
    local c; c=$(mktemp "$work_dir/.config.XXXXXX")
    jq '(.inbounds[]|select(.protocol=="vless" and .streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp" or .streamSettings.network=="grpc"))) |= (del(.streamSettings.grpcSettings) | .streamSettings.network="raw" | (.settings.clients[].flow)="xtls-rprx-vision")' "$config_dir" > "$c"
    validate_xray_config "$c" || { rm -f "$c"; return 1; }; chmod 600 "$c"; mv "$c" "$config_dir"
    chmod 711 "$work_dir"
    generate_subscription || return 1
    write_nginx_config && nginx -t -c "$work_dir/nginx.conf" >/dev/null 2>&1 || return 1
    # 到这里配置已全部验证，才交接监听端口。
    if [ ! -f "$work_dir/.caddy-retired" ] && [ -f /etc/caddy/Caddyfile ] && legacy_owned /etc/caddy/Caddyfile; then stop_owned_caddy || return 1; fi
    legacy_retire || return 1
    install_runtime_copy || return 1
    configure_services || return 1
    start_services || { red '迁移启动未通过，请保留备份并检查服务'; return 1; }
    touch "$work_dir/.installed"
    trap - EXIT
    green '迁移完成：原订阅端口、路径和认证已保留。NAT 映射无需改变。'
)

install_fresh() {
    [ ! -e "$config_dir" ] || { red '已有配置，请使用 --upgrade，避免覆盖认证信息'; return 1; }
    install_dependencies || return 1
    mkdir -p "$work_dir"; chmod 711 "$work_dir"; umask 077
    local arch xr uuid private pub output subp rawp xhp ap name server
    case $(uname -m) in
        x86_64|amd64) arch=amd64; xr=64;; aarch64|arm64) arch=arm64; xr=arm64-v8a;;
        i386|i686) arch=386; xr=32;; armv7l) arch=arm; xr=arm32-v7a;; *) red '不支持的 CPU 架构';return 1;;
    esac
    subp=${PORT:-$(shuf -i 10000-60000 -n 1)}; rawp=${RAW_PORT:-$((subp+1))}; xhp=${XHTTP_PORT:-$((subp+2))}; ap=${ARGO_PORT:-8080}
    for output in "$subp" "$rawp" "$xhp" "$ap"; do port_available "$output" || { red '安装端口无效或占用'; return 1; }; done
    [ "$(printf '%s\n' "$subp" "$rawp" "$xhp" "$ap" | sort -u | wc -l)" -eq 4 ] || return 1
    curl -fSL --retry 2 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-'"$xr"'.zip' -o "$work_dir/core.zip" || return 1
    unzip -oq "$work_dir/core.zip" xray -d "$work_dir" || return 1
    curl -fSL --retry 2 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-'"$arch" -o "$work_dir/argo" || return 1
    chmod 700 "$work_dir/xray" "$work_dir/argo"; rm -f "$work_dir/core.zip"
    uuid=${UUID:-$(random_uuid)}; output=$("$work_dir/xray" x25519) || return 1
    private=$(awk '/^PrivateKey/{print $NF}' <<< "$output"); [ -n "$private" ] || return 1
    server=${SERVER_IP:-$(get_realip)}; server=$(normalize_host "$server"); valid_host "$server" || return 1
    name=${NODE_NAME:-$(hostname)}
    jq -n --arg id "$uuid" --arg private "$private" --argjson raw "$rawp" --argjson xh "$xhp" --argjson ap "$ap" '{log:{access:"/dev/null",error:"/dev/null",loglevel:"none"},inbounds:[{tag:"argo-entry",listen:"127.0.0.1",port:$ap,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none",fallbacks:[{dest:3001},{path:"/vless-argo",dest:3002},{path:"/vmess-argo",dest:3003}]},streamSettings:{network:"raw"}},{tag:"fallback",listen:"127.0.0.1",port:3001,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"raw"}},{tag:"vless-ws",listen:"127.0.0.1",port:3002,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"ws",wsSettings:{path:"/vless-argo"}}},{tag:"vmess-ws",listen:"127.0.0.1",port:3003,protocol:"vmess",settings:{clients:[{id:$id}]},streamSettings:{network:"ws",wsSettings:{path:"/vmess-argo"}}},{tag:"raw-reality",port:$raw,protocol:"vless",settings:{clients:[{id:$id,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{target:"www.iij.ad.jp:443",serverNames:["www.iij.ad.jp"],privateKey:$private,shortIds:[""]}}},{tag:"xhttp-reality",port:$xh,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"xhttp",security:"reality",realitySettings:{target:"www.nazhumi.com:443",serverNames:["www.nazhumi.com"],privateKey:$private,shortIds:[""]}}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$config_dir"
    validate_xray_config "$config_dir" || return 1
    jq -n --arg name "$name" --arg server "$server" --arg cdn "${CFIP:-cdns.doon.eu.org}" --argjson cp "${CFPORT:-443}" --arg path "$(random_path)" --argjson sp "$subp" --argjson ap "$ap" '{version:2,name:$name,server:$server,cdn:$cdn,cdn_port:$cp,subscription_port:$sp,subscription_path:$path,subscription_enabled:true,tunnel_mode:"quick",tunnel_domain:"",argo_port:$ap}' > "$state_file"
    generate_subscription; write_nginx_config
    nginx -t -c "$work_dir/nginx.conf" >/dev/null 2>&1 || return 1
    install_runtime_copy && configure_services && start_services || return 1
    touch "$work_dir/.installed"
    green '安装完成。NAT 机器须映射订阅和两个直连 TCP 端口；Argo 无需映射内部端口。'
}

tunnel_transaction() (
    local b f r
    b=$(mktemp -d "$work_dir/.tunnel-change.XXXXXX"); chmod 700 "$b"
    for f in state.json config.json tunnel.token tunnel.json tunnel.yml argo.log url.txt; do [ ! -f "$work_dir/$f" ] || cp -p "$work_dir/$f" "$b/$f";done
    trap 'r=$?; if [ "$r" -ne 0 ];then
        for f in state.json config.json tunnel.token tunnel.json tunnel.yml argo.log url.txt;do
            if [ -f "$b/$f" ];then cp -p "$b/$f" "$work_dir/$f";else rm -f "$work_dir/$f";fi
        done
        generate_subscription_unlocked || true
        service_action xray2go-core restart || true
        service_action xray2go-tunnel restart || true
    fi
    rm -rf "$b"' EXIT
    "$@"
)
set_tunnel() { with_lock tunnel_transaction set_tunnel_unlocked "$@"; }
set_tunnel_unlocked() {
    local mode=$1 domain=${2:-} credential=${3:-} ap
    [[ "$mode" == quick || "$mode" == token || "$mode" == json ]] || return 1
    [ "$mode" = quick ] || valid_host "$domain" || return 1
    ap=$(state argo_port)
    if [ "$mode" = token ]; then
        [ -s "$credential" ] && [[ "$(cat "$credential")" =~ ^[A-Za-z0-9_=.-]+$ ]] || return 1
        cp "$credential" "$work_dir/tunnel.token" && chmod 600 "$work_dir/tunnel.token" || return 1
    elif [ "$mode" = json ]; then
        jq -e '.TunnelID and .TunnelSecret and .AccountTag' "$credential" >/dev/null || return 1
        cp "$credential" "$work_dir/tunnel.json"; chmod 600 "$work_dir/tunnel.json"
        printf 'tunnel: %s\ncredentials-file: %s/tunnel.json\nprotocol: http2\ningress:\n  - hostname: %s\n    service: http://127.0.0.1:%s\n  - service: http_status:404\n' "$(jq -r .TunnelID "$credential")" "$work_dir" "$domain" "$ap" > "$work_dir/tunnel.yml"
        chmod 600 "$work_dir/tunnel.yml"
    fi
    set_tunnel_state "$mode" "$domain" || return 1
    service_action xray2go-tunnel restart
}
set_tunnel_state() {
    state_string tunnel_mode "$1"
    if [ "$1" = quick ]; then : > "$work_dir/argo.log"; state_string tunnel_domain ''
    else state_string tunnel_domain "$2"; fi
    generate_subscription_unlocked
}
renew_tunnel() {
    [ "$(state tunnel_mode)" = quick ] || { red '固定隧道不申请临时域名'; return 1; }
    # 手动请求也保留 60 秒冷却，防止反复申请触发 Cloudflare 429。
    local now last=0; now=$(date +%s)
    [ ! -f "$work_dir/last-renew" ] || read -r last < "$work_dir/last-renew"
    ((now-last>=60)) || { red '请等待 60 秒后再申请'; return 1; }
    printf '%s\n' "$now" > "$work_dir/last-renew"
    service_action xray2go-tunnel restart
}
set_argo_port() { with_lock tunnel_transaction set_argo_port_unlocked "$1"; }
set_argo_port_unlocked() {
    local port=$1 old c
    old=$(state argo_port); port_available "$port" "$old" || return 1
    c=$(mktemp "$work_dir/.config.XXXXXX")
    jq --argjson p "$port" '(.inbounds[]|select(.settings.fallbacks).port)=$p' "$config_dir" > "$c"
    apply_xray_config "$c" || return 1
    state_set argo_port "$port"
    if [ "$(state tunnel_mode)" = json ]; then sed -i -E "s#http://(localhost|127.0.0.1):[0-9]+#http://127.0.0.1:$port#" "$work_dir/tunnel.yml"; fi
    service_action xray2go-tunnel restart
}
set_server_address() {
    local address; address=$(normalize_host "$1"); valid_host "$address" || return 1
    with_lock update_address_state "$address"
}
update_address_state() { state_string server "$1"; generate_subscription_unlocked; }
set_cdn() {
    local h;h=$(normalize_host "$1"); valid_host "$h" && valid_port "$2" || return 1
    with_lock update_cdn_state "$h" "$2"
}
update_cdn_state() { state_string cdn "$1"; state_set cdn_port "$2"; generate_subscription_unlocked; }

# 不卸载共享 Nginx 软件包，不调用 nginx -s stop，不碰 ArgoX 的服务。
uninstall_owned() {
    [ "$work_dir" = /etc/xray ] && [ -f "$work_dir/.installed" ] || { red '未识别到本脚本安装标识';return 1; }
    local s f
    for s in xray2go-sync xray2go-sub xray2go-tunnel xray2go-core; do
        if is_openrc; then f="$init_dir/$s"; else f="$systemd_dir/$s.service"; fi
        [ ! -f "$f" ] || grep -Fq 'Managed by shadowxhero/xray-2go' "$f" || { red '服务归属冲突，停止卸载';return 1; }
    done
    backup_installation || return 1
    for s in xray2go-sync xray2go-sub xray2go-tunnel xray2go-core; do
        service_action "$s" stop || { red "无法停止 $s，保留服务文件以便排查"; return 1; }
        stop_owned_processes "${s#xray2go-}" || { red "仍有 $s 进程，停止卸载";return 1; }
        service_disable "$s"
        rm -f "$init_dir/$s" "$systemd_dir/$s.service"
    done
    stop_legacy_sync_processes
    if ! is_openrc; then systemctl daemon-reload; fi
    if [ -f /usr/bin/2go ] && grep -Fq /etc/xray/runtime.sh /usr/bin/2go; then rm -f /usr/bin/2go; fi
    local retired="/root/xray2go-uninstalled-$(date +%Y%m%d-%H%M%S)"
    [ "$(readlink -f "$work_dir")" = /etc/xray ] && [ ! -e "$retired" ] || return 1
    mv "$work_dir" "$retired"; chmod 700 "$retired"
    green '服务、开机项已移除；配置和密钥已归档到 root 目录，不再有后台进程。'
}
show_nodes() {
    [ -f "$client_dir" ] || return 1
    cat "$client_dir"
    printf '\n订阅：http://%s:%s/%s\n' "$(host_uri "$(state server)")" "$(state subscription_port)" "$(state subscription_path)"
    printf 'NAT：订阅端口必须在服务商面板映射；服务器内本机 HTTP 成功不代表公网已映射。\n'
}
show_status() {
    local s
    printf 'Xray-2go v%s\n' "$SCRIPT_VERSION"
    for s in "${SERVICES[@]}"; do if service_status "$s"; then printf '%s: running\n' "$s"; else printf '%s: stopped\n' "$s";fi;done
}
menu() {
    local choice value network h p mode domain file
    while true; do
        show_status
        printf '\n1. 新安装\n2. 升级/从 Caddy 迁移（保留配置）\n3. 查看节点与订阅\n4. 修改节点名称\n5. 修改 RAW 端口\n6. 修改 XHTTP 端口\n7. 修改订阅端口\n8. 订阅启用/关闭\n9. 服务启停\n10. 隧道管理\n11. 修改 UUID\n12. 修改 Reality SNI\n13. 修改 Argo 优选地址/端口\n14. 修改直连 IP（IPv4/IPv6）\n15. 修改 Argo 内部端口\n16. 卸载\n0. 退出\n'
        reading '选择：' choice
        case "$choice" in
            1) install_fresh ;;
            2) upgrade_installation ;;
            3) show_nodes ;;
            4) reading '基础名：' value; with_lock rename_nodes "$value" ;;
            5|6) network=raw; [ "$choice" != 6 ] || network=xhttp; reading '新端口：' value; set_direct_port "$network" "$value" ;;
            7) reading '新订阅端口：' value; set_subscription_port "$value" ;;
            8) reading '1 开启，0 关闭（不会被自愈自动开启）：' value; if [ "$value" = 1 ];then set_subscription_enabled true;else set_subscription_enabled false;fi ;;
            9) reading '服务 core/tunnel/sub/sync：' value; reading '操作 start/stop/restart：' choice; case "$value:$choice" in core:start|core:stop|core:restart|tunnel:start|tunnel:stop|tunnel:restart|sub:start|sub:stop|sub:restart|sync:start|sync:stop|sync:restart) service_action "xray2go-$value" "$choice";; *) red '无效操作';; esac ;;
            10) reading 'quick/token/json/renew：' mode; if [ "$mode" = renew ];then renew_tunnel; elif [ "$mode" = quick ];then set_tunnel quick;else reading '固定隧道域名：' domain; reading '凭据文件路径（不在终端粘贴密钥）：' file;set_tunnel "$mode" "$domain" "$file";fi ;;
            11) reading '新 UUID（留空随机）：' value; set_uuid "${value:-$(random_uuid)}" ;;
            12) reading 'raw 或 xhttp：' network; reading 'SNI 域名：' value; set_sni "$network" "$value" ;;
            13) reading '优选域名/IP：' h; reading '优选端口：' p;set_cdn "$h" "$p" ;;
            14) reading '实际公网入站 IP（不是 WARP 出口）：' value;set_server_address "$value" ;;
            15) reading 'Argo 内部新端口：' value;set_argo_port "$value" ;;
            16) reading '确认卸载本脚本并归档配置？输入 yes：' value;[ "$value" != yes ] || uninstall_owned ;;
            0) return 0 ;;
            *) red '无效选项' ;;
        esac
    done
}
rename_nodes() { [ -n "$1" ] && state_string name "$1" && generate_subscription_unlocked; }
main() {
    case "${1:-}" in
        --version) printf '%s\n' "$SCRIPT_VERSION"; return;;
        -h|--help) printf '2go [-i|--install] [--upgrade] [-c|--check] [-r|--restart] [-u|--uninstall] [--sync] [--version]\n--upgrade 保留端口、订阅路径、UUID、密钥和固定隧道；不会重新下载内核。\n';return;;
    esac
    require_root || return 1
    case "${1:-}" in
        -i|--install|--upgrade|'') resolve_self || return 1;;
    esac
    case "${1:-}" in
        -i|--install) install_fresh;;
        --upgrade) upgrade_installation;;
        -c|--check) show_nodes;;
        -r|--restart) renew_tunnel;;
        -u|--uninstall) uninstall_owned;;
        --sync) sync_subscription;;
        --tunnel-worker) tunnel_worker;;
        '') menu;;
        *) red '未知参数，请用 --help';return 1;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
