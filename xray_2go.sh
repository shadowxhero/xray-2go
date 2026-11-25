#!/usr/bin/env bash
# Xray-2go v2.1.6 — based on eooce/xray-2go (MIT).
# 专属 Nginx、原生服务监督、原子订阅、隧道存活探测与安全迁移。2026-11-25

SCRIPT_VERSION=2.1.6
work_dir=/etc/xray
config_dir="$work_dir/config.json"
client_dir="$work_dir/url.txt"
state_file="$work_dir/state.json"
init_dir=/etc/init.d
systemd_dir=/etc/systemd/system
run_dir=/run
shortcut_path=/usr/bin/2go
archive_root=/root
argox_config=/etc/argox/inbound.json
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
# 沿用 Sing-box 的国家代码-服务商基础名；自定义 NODE_NAME 优先。
resolve_node_name() {
    if [ -n "${NODE_NAME:-}" ]; then printf '%s\n' "$NODE_NAME"; return 0; fi
    local endpoint data name
    for endpoint in https://api.ip.sb/geoip https://ipapi.co/json; do
        data=$(curl -fsS --max-time 4 "$endpoint" 2>/dev/null) || continue
        name=$(jq -er 'select((.country_code|type)=="string") | (.isp // .org // "") as $isp | select((.country_code|length)>0 and ($isp|length)>0) | .country_code+"-"+$isp | gsub("[[:space:]]+";"_")' <<< "$data" 2>/dev/null) || continue
        printf '%s\n' "$name";return 0
    done
    hostname
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
validate_xray_config() {
    local staged check result=0
    # Alpine 默认的 busybox mktemp 只接受以 XXXXXX 结尾的模板（没有 GNU 的 --suffix），
    # 写成 ".validate.XXXXXX.json" 会直接 EINVAL。后缀只能在模板之后自己拼。
    staged=$(mktemp "$work_dir/.validate.XXXXXX") || return 1
    check="$staged.json"
    cp "$1" "$check" || { rm -f "$staged" "$check"; return 1; }
    rm -f "$staged"; chmod 600 "$check"
    "$work_dir/xray" run -test -format json -c "$check" >/dev/null 2>&1 || result=$?
    rm -f "$check"; return "$result"
}

# 四个节点可独立启停。argo 的两个节点共用一条 cloudflared 隧道，
# 只有两个都关闭时才停止 tunnel 服务；fallback/argo-entry 也一起移除。
ALL_PROTOCOLS=(raw-reality xhttp-reality vless-argo vmess-argo)
protocol_label() {
    case "$1" in
        raw-reality) printf 'VLESS RAW + REALITY + Vision' ;;
        xhttp-reality) printf 'VLESS XHTTP + REALITY' ;;
        vless-argo) printf 'VLESS WebSocket + Argo' ;;
        vmess-argo) printf 'VMess WebSocket + Argo' ;;
        *) return 1 ;;
    esac
}
# 老版本 state 没有 protocols 字段，按真实入站反推，保证升级后状态与配置一致。
protocols_detect() {
    local list=()
    [ -s "$config_dir" ] || { printf '%s\n' "${ALL_PROTOCOLS[@]}"; return 0; }
    jq -e '.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp"))' "$config_dir" >/dev/null 2>&1 && list+=(raw-reality)
    jq -e '.inbounds[]|select(.streamSettings.security=="reality" and .streamSettings.network=="xhttp")' "$config_dir" >/dev/null 2>&1 && list+=(xhttp-reality)
    jq -e '.inbounds[]|select(.tag=="vless-ws")' "$config_dir" >/dev/null 2>&1 && list+=(vless-argo)
    jq -e '.inbounds[]|select(.tag=="vmess-ws")' "$config_dir" >/dev/null 2>&1 && list+=(vmess-argo)
    [ "${#list[@]}" -gt 0 ] || list=("${ALL_PROTOCOLS[@]}")
    printf '%s\n' "${list[@]}"
}
protocols_current() {
    local stored
    stored=$(jq -r 'if (.protocols|type)=="array" then .protocols[] else empty end' "$state_file" 2>/dev/null)
    if [ -n "$stored" ]; then printf '%s\n' "$stored"; else protocols_detect; fi
}
protocol_enabled() {
    local want=$1 p
    for p in $(protocols_current); do [ "$p" = "$want" ] && return 0; done
    return 1
}
protocols_joined() { printf '%s\n' "$(protocols_current)" | paste -sd, - 2>/dev/null || printf '%s\n' "$(protocols_current)" | tr '\n' ',' | sed 's/,$//'; }
protocol_listed() {
    local want=$1 list=${2//$'\n'/ } item
    for item in $list; do [ "$item" = "$want" ] && return 0; done
    return 1
}
protocols_state_set() {
    local json
    json=$(printf '%s\n' "$@" | jq -R . | jq -sc .) || return 1
    state_set protocols "$json"
}
# 安装时用编号选协议：1234=全装，13=raw 与 vless-argo，, / 空格可分隔，重复项自动去重。
protocols_from_digits() {
    local digits=$1 d seen=" " out=()
    digits=${digits//[ ,]/}
    if [ -z "$digits" ]; then printf '%s\n' "${ALL_PROTOCOLS[*]}" | tr ' ' ','; return 0; fi
    [[ "$digits" =~ ^[1-4]+$ ]] || return 1
    for ((d=0; d<${#digits}; d++)); do seen="$seen${digits:d:1} "; done
    for d in 1 2 3 4; do
        case "$seen" in *" $d "*) out+=("${ALL_PROTOCOLS[$((d-1))]}");; esac
    done
    (IFS=,; printf '%s\n' "${out[*]}")
}
protocols_normalize() {    # 校验并规范化为 ALL_PROTOCOLS 的顺序，去重、忽略未知项。
    local raw=$1 out=() item p found
    local items=(${raw//,/ })
    for item in "${items[@]}"; do
        found=0
        for p in "${ALL_PROTOCOLS[@]}"; do [ "$item" = "$p" ] && { found=1; break; }; done
        [ "$found" = 1 ] || { red "未知协议：$item（可选：${ALL_PROTOCOLS[*]}）"; return 1; }
    done
    for p in "${ALL_PROTOCOLS[@]}"; do
        for item in "${items[@]}"; do [ "$item" = "$p" ] && { out+=("$p"); break; }; done
    done
    [ "${#out[@]}" -gt 0 ] || { red '至少要保留一个协议。'; return 1; }
    printf '%s\n' "${out[@]}"
}
any_argo_protocol() { protocol_enabled vless-argo || protocol_enabled vmess-argo; }

# 始终由真实入站和持久状态重新导出，不对 URI 做固定行号/IPv4 正则替换。
generate_subscription() { with_lock generate_subscription_unlocked; }
generate_subscription_unlocked() {
    local pub server cdn cp domain name raw xhttp id vless_raw vless_xhttp vm tmp sub a b c d enabled
    local -a lines=()
    server=$(state server) || return 1; server=$(host_uri "$server")
    cdn=$(state cdn) || return 1; cdn=$(host_uri "$cdn")
    cp=$(state cdn_port); domain=$(state tunnel_domain) || domain=''
    name=$(state name) || name=vps
    enabled=$(protocols_current)
    a=$(uri "$name-RAW-Reality"); b=$(uri "$name-XHTTP-Reality"); c=$(uri "$name-VLESS-Argo")
    if protocol_listed raw-reality "$enabled"; then
        raw=$(jq -ce '.inbounds[]|select(.protocol=="vless" and .streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp"))' "$config_dir") || return 1
        id=$(jq -er '.settings.clients[0].id' <<< "$raw") || return 1
        pub=$(derive_public_key "$(jq -r '.streamSettings.realitySettings.privateKey' <<< "$raw")") || return 1
        vless_raw="vless://$id@$server:$(jq -r .port <<< "$raw")?encryption=none&security=reality&sni=$(uri "$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<< "$raw")")&fp=chrome&pbk=$pub&type=tcp&headerType=none&flow=xtls-rprx-vision&sid=$(jq -r '.streamSettings.realitySettings.shortIds[0] // ""' <<< "$raw")#$a"
        lines+=("$vless_raw")
    fi
    if protocol_listed xhttp-reality "$enabled"; then
        xhttp=$(jq -ce '.inbounds[]|select(.protocol=="vless" and .streamSettings.security=="reality" and .streamSettings.network=="xhttp")' "$config_dir") || return 1
        id=$(jq -er '.settings.clients[0].id' <<< "$xhttp") || return 1
        pub=$(derive_public_key "$(jq -r '.streamSettings.realitySettings.privateKey' <<< "$xhttp")") || return 1
        vless_xhttp="vless://$id@$server:$(jq -r .port <<< "$xhttp")?encryption=none&security=reality&sni=$(uri "$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<< "$xhttp")")&fp=chrome&pbk=$pub&type=xhttp&mode=auto&sid=$(jq -r '.streamSettings.realitySettings.shortIds[0] // ""' <<< "$xhttp")#$b"
        lines+=("$vless_xhttp")
    fi
    if protocol_listed vless-argo "$enabled"; then
        id=$(jq -er '.inbounds[]|select(.tag=="vless-ws")|.settings.clients[0].id' "$config_dir") || return 1
        d="vless://$id@$cdn:$cp?encryption=none&security=tls&sni=$(uri "$domain")&fp=chrome&type=ws&host=$(uri "$domain")&path=%2Fvless-argo%3Fed%3D2560#$c"
        lines+=("$d")
    fi
    if protocol_listed vmess-argo "$enabled"; then
        id=$(jq -er '.inbounds[]|select(.tag=="vmess-ws")|.settings.clients[0].id' "$config_dir") || return 1
        vm=$(jq -cn --arg name "$name-VMess-Argo" --arg address "$(state cdn)" --arg port "$cp" --arg uuid "$id" --arg domain "$domain" '{v:"2",ps:$name,add:$address,port:$port,id:$uuid,aid:"0",scy:"aes-128-gcm",net:"ws",type:"none",host:$domain,path:"/vmess-argo?ed=2560",tls:"tls",sni:$domain,alpn:"",fp:"chrome"}' | base64 | tr -d '\n') || return 1
        lines+=("vmess://$vm")
    fi
    [ "${#lines[@]}" -gt 0 ] || { red '没有启用任何协议，订阅无法生成。'; return 1; }
    mkdir -p "$work_dir/public"; chmod 755 "$work_dir/public"
    tmp=$(mktemp "$work_dir/.urls.XXXXXX"); sub=$(mktemp "$work_dir/public/.sub.XXXXXX") || return 1
    printf '%s\n' "${lines[@]}" > "$tmp"
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

# ---- 协议增删（运行时） ----
pick_free_port() {
    local i p
    for i in $(seq 1 100); do
        p=$(random_port_candidate)
        case "$p" in 3001|3002|3003) continue ;; esac
        port_available "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
# 端口记忆：删掉协议后仍保留在 state.ports，加回来时优先复用同一个端口。
protocol_port_get() {
    local name=$1 p
    p=$(jq -r --arg k "$name" '.ports[$k] // empty' "$state_file" 2>/dev/null)
    if [ -z "$p" ]; then
        if [ "$name" = raw ]; then
            p=$(jq -r '(.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp"))).port // empty' "$config_dir" 2>/dev/null | head -1)
        else
            p=$(jq -r '(.inbounds[]|select(.streamSettings.security=="reality" and .streamSettings.network=="xhttp")).port // empty' "$config_dir" 2>/dev/null | head -1)
        fi
    fi
    [ -n "$p" ] && printf '%s\n' "$p"
}
protocol_port_remember() {
    local k=$1 p=$2 t
    [ -n "$p" ] || return 0
    t=$(mktemp "$work_dir/.state.XXXXXX") || return 1
    jq --arg k "$k" --argjson p "$p" '.ports = ((.ports // {}) + {($k): $p})' "$state_file" > "$t" \
        && chmod 600 "$t" && mv "$t" "$state_file" || { rm -f "$t"; return 1; }
}
reality_field() {
    local network=$1 field=$2
    if [ "$network" = raw ]; then
        jq -r --arg f "$field" '(.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp")))|if $f=="sni" then (.streamSettings.realitySettings.serverNames[0] // "") else .streamSettings.realitySettings.privateKey end' "$config_dir" 2>/dev/null | head -1
    else
        jq -r --arg f "$field" '(.inbounds[]|select(.streamSettings.security=="reality" and .streamSettings.network=="xhttp"))|if $f=="sni" then (.streamSettings.realitySettings.serverNames[0] // "") else .streamSettings.realitySettings.privateKey end' "$config_dir" 2>/dev/null | head -1
    fi
}
new_reality_key() {
    local output priv
    output=$("$work_dir/xray" x25519) || return 1
    priv=$(printf '%s\n' "$output" | awk '/^PrivateKey/{print $NF}')
    [ -n "$priv" ] && printf '%s\n' "$priv"
}
protocol_uuid() {
    jq -r '[.inbounds[].settings.clients[]?.id]|map(select(.!=null))|first // empty' "$config_dir" 2>/dev/null
}
apply_protocols() { with_lock apply_protocols_unlocked "$@"; }
apply_protocols_unlocked() {
    local wanted old candidate uuid argo_port p priv snin vl vm old_joined new_joined
    local -a wanted_arr=() old_arr=()
    wanted=$(protocols_normalize "$1") || return 1
    while IFS= read -r line; do [ -n "$line" ] && wanted_arr+=("$line"); done <<< "$wanted"
    old=$(protocols_current)
    while IFS= read -r line; do [ -n "$line" ] && old_arr+=("$line"); done <<< "$old"
    old_joined="${old_arr[*]}"; new_joined="${wanted_arr[*]}"
    [ "$old_joined" = "$new_joined" ] && { green '协议未变化。'; return 0; }
    uuid=$(protocol_uuid); [ -n "$uuid" ] || { red '配置里找不到 UUID。'; return 1; }
    argo_port=$(state argo_port) || argo_port=8080
    candidate=$(mktemp "$work_dir/.config.XXXXXX") || return 1
    cp -p "$config_dir" "$candidate" || { rm -f "$candidate"; return 1; }

    if protocol_listed raw-reality "$wanted"; then
        if ! jq -e '.inbounds[]|select(.tag=="raw-reality")' "$candidate" >/dev/null 2>&1; then
            p=$(protocol_port_get raw); [ -n "$p" ] || p=$(pick_free_port)
            priv=$(reality_field raw privateKey); [ -n "$priv" ] || priv=$(new_reality_key)
            snin=$(reality_field raw sni); [ -n "$snin" ] || snin=$(reality_field xhttp sni); [ -n "$snin" ] || snin=www.iij.ad.jp
            if [ -z "$p" ] || [ -z "$priv" ]; then rm -f "$candidate"; red '无法为 RAW 协议分配端口或密钥。'; return 1; fi
            jq --arg id "$uuid" --arg priv "$priv" --arg snin "$snin" --argjson port "$p" '.inbounds += [{tag:"raw-reality",port:$port,protocol:"vless",settings:{clients:[{id:$id,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{target:($snin+":443"),serverNames:[$snin],privateKey:$priv,shortIds:[""]}}}]' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
            protocol_port_remember raw "$p"
        fi
    else
        p=$(protocol_port_get raw)
        jq 'del(.inbounds[]|select(.tag=="raw-reality"))' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
        protocol_port_remember raw "$p"
    fi

    if protocol_listed xhttp-reality "$wanted"; then
        if ! jq -e '.inbounds[]|select(.tag=="xhttp-reality")' "$candidate" >/dev/null 2>&1; then
            p=$(protocol_port_get xhttp); [ -n "$p" ] || p=$(pick_free_port)
            priv=$(reality_field xhttp privateKey); [ -n "$priv" ] || priv=$(new_reality_key)
            snin=$(reality_field xhttp sni); [ -n "$snin" ] || snin=$(reality_field raw sni); [ -n "$snin" ] || snin=www.nazhumi.com
            if [ -z "$p" ] || [ -z "$priv" ]; then rm -f "$candidate"; red '无法为 XHTTP 协议分配端口或密钥。'; return 1; fi
            jq --arg id "$uuid" --arg priv "$priv" --arg snin "$snin" --argjson port "$p" '.inbounds += [{tag:"xhttp-reality",port:$port,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"xhttp",security:"reality",realitySettings:{target:($snin+":443"),serverNames:[$snin],privateKey:$priv,shortIds:[""]}}}]' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
            protocol_port_remember xhttp "$p"
        fi
    else
        p=$(protocol_port_get xhttp)
        jq 'del(.inbounds[]|select(.tag=="xhttp-reality"))' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
        protocol_port_remember xhttp "$p"
    fi

    if protocol_listed vless-argo "$wanted"; then
        if ! jq -e '.inbounds[]|select(.tag=="vless-ws")' "$candidate" >/dev/null 2>&1; then
            jq --arg id "$uuid" '.inbounds += [{tag:"vless-ws",listen:"127.0.0.1",port:3002,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"ws",wsSettings:{path:"/vless-argo"}}}]' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
        fi
    else
        jq 'del(.inbounds[]|select(.tag=="vless-ws"))' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
    fi

    if protocol_listed vmess-argo "$wanted"; then
        if ! jq -e '.inbounds[]|select(.tag=="vmess-ws")' "$candidate" >/dev/null 2>&1; then
            jq --arg id "$uuid" '.inbounds += [{tag:"vmess-ws",listen:"127.0.0.1",port:3003,protocol:"vmess",settings:{clients:[{id:$id}]},streamSettings:{network:"ws",wsSettings:{path:"/vmess-argo"}}}]' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
        fi
    else
        jq 'del(.inbounds[]|select(.tag=="vmess-ws"))' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
    fi

    # argo-entry/fallback 每次重建，保证 fallbacks 只指向真正启用的路径。
    jq 'del(.inbounds[]|select(.tag=="argo-entry" or .tag=="fallback"))' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
    if protocol_listed vless-argo "$wanted" || protocol_listed vmess-argo "$wanted"; then
        vl=0; vm=0
        protocol_listed vless-argo "$wanted" && vl=1
        protocol_listed vmess-argo "$wanted" && vm=1
        jq --arg id "$uuid" --argjson ap "$argo_port" --argjson vl "$vl" --argjson vm "$vm" '.inbounds += [{tag:"argo-entry",listen:"127.0.0.1",port:$ap,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none",fallbacks:([{dest:3001}]+(if $vl==1 then [{path:"/vless-argo",dest:3002}] else [] end)+(if $vm==1 then [{path:"/vmess-argo",dest:3003}] else [] end))},streamSettings:{network:"raw"}},{tag:"fallback",listen:"127.0.0.1",port:3001,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"raw"}}]' "$candidate" > "$candidate.new" && mv "$candidate.new" "$candidate" || { rm -f "$candidate" "$candidate.new"; return 1; }
    fi

    protocols_state_set "${wanted_arr[@]}" || { rm -f "$candidate"; return 1; }
    if ! apply_xray_config "$candidate"; then
        protocols_state_set "${old_arr[@]}" || true
        red '协议变更未生效，已恢复原状态。'
        return 1
    fi
    if protocol_listed vless-argo "$wanted" || protocol_listed vmess-argo "$wanted"; then
        service_enable xray2go-tunnel >/dev/null 2>&1 || true
        service_action xray2go-tunnel restart || true
    else
        service_action xray2go-tunnel stop || true
        service_disable xray2go-tunnel || true
    fi
    green "已启用协议：${new_joined}"
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
    # 同步器只同步订阅，不检查/重启 Xray 或 Nginx；隧道存活交给 --health 单独探测，
    # 因为临时隧道被云端回收时 cloudflared 不会退出，respawn 与日志抓取都不会触发。
    # 探测每 6 轮（约 60 秒）执行一次，避免小内存机器上频繁 fork 脚本进程。
    cat > "$work_dir/sync-loop.sh" <<EOF
#!/bin/sh
# Managed by shadowxhero/xray-2go
n=0
while true; do
    /bin/bash "$work_dir/runtime.sh" --sync >/dev/null 2>&1
    n=\$((n + 1))
    [ \$((n % 6)) -eq 0 ] && /bin/bash "$work_dir/runtime.sh" --health >/dev/null 2>&1
    sleep 10
done
EOF
    cat > "$work_dir/tunnel-worker.sh" <<EOF
#!/bin/sh
# Managed by shadowxhero/xray-2go
export GOMEMLIMIT=20MiB GOGC=15
exec /bin/bash "$work_dir/runtime.sh" --tunnel-worker
EOF
    chmod 700 "$work_dir/sync-loop.sh" "$work_dir/tunnel-worker.sh"
}

write_openrc_services() {
    local name cmd args delay oom_adj
    mkdir -p "$init_dir"
    for name in "${SERVICES[@]}"; do
        delay=5; oom_adj=0
        case "$name" in
            xray2go-core) cmd="$work_dir/xray"; args="run -c $config_dir"; oom_adj=-500 ;;
            xray2go-tunnel) cmd="$work_dir/tunnel-worker.sh"; args=''; delay=60; oom_adj=-500 ;;
            xray2go-sub) cmd=$(command -v nginx); args="-c $work_dir/nginx.conf -g 'daemon off;'" ;;
            xray2go-sync) cmd="$work_dir/sync-loop.sh"; args=''; oom_adj=500 ;;
        esac
        # 小内存机器上 OOM killer 按 oom_badness 选目标：xray/cloudflared 占用最大，
        # 不调整就总是它们先被杀；cloudflared 一旦重启会重新申请临时隧道、换域名，
        # 客户端随即失效。这里把两条关键链路设为难以被杀，让同步器（5 秒拉起、无副作用）
        # 承担被杀的代价。
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
export GOMEMLIMIT=${XRAY_GOMEMLIMIT:-32MiB}
export GOGC=${XRAY_GOGC:-20}
start_pre() {
    [ -w /proc/self/oom_score_adj ] && echo $oom_adj > /proc/self/oom_score_adj
    return 0
}
depend() { need net; }
EOF
        chmod 755 "$init_dir/$name"
    done
}
write_systemd_services() {
    local name exec delay oom_adj
    mkdir -p "$systemd_dir"
    for name in "${SERVICES[@]}"; do
        delay=5; oom_adj=0
        case "$name" in
            xray2go-core) exec="$work_dir/xray run -c $config_dir"; oom_adj=-500 ;;
            xray2go-tunnel) exec="$work_dir/tunnel-worker.sh"; delay=60; oom_adj=-500 ;;
            xray2go-sub) exec="$(command -v nginx) -c $work_dir/nginx.conf -g 'daemon off;'" ;;
            xray2go-sync) exec="$work_dir/sync-loop.sh"; oom_adj=500 ;;
        esac
        # 同 openrc：保护 xray/cloudflared 不被 OOM 优先选中，让同步器承担重启代价。
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
OOMScoreAdjust=$oom_adj
Environment="GOMEMLIMIT=${XRAY_GOMEMLIMIT:-32MiB}" "GOGC=${XRAY_GOGC:-20}"
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
    export GOMEMLIMIT=${ARGO_GOMEMLIMIT:-20MiB} GOGC=${ARGO_GOGC:-15}
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
    local p path i probe nginx_pid
    p=$(state subscription_port); path=$(state subscription_path)
    probe=$(mktemp "$work_dir/.probe.XXXXXX") || return 1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        nginx_pid=''; [ ! -s "$work_dir/nginx.pid" ] || read -r nginx_pid < "$work_dir/nginx.pid"
        if [[ "$nginx_pid" =~ ^[0-9]+$ ]] && [ "$(readlink "/proc/$nginx_pid/exe" 2>/dev/null)" = "$(command -v nginx)" ] && curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$p/$path" -o "$probe" 2>/dev/null && cmp -s "$probe" "$work_dir/public/sub.txt"; then
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
    if [ -e "$shortcut_path" ] || [ -L "$shortcut_path" ]; then cp -a "$shortcut_path" "$b/shortcut.before"; fi
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
    if is_openrc; then
        if [ -f "$init_dir/caddy" ]; then
            rc-service caddy stop >/dev/null 2>&1 || return 1
        else
            local p exe
            for p in /proc/[0-9]*; do
                exe=$(readlink "$p/exe" 2>/dev/null) || continue
                case "$exe" in */caddy|*/caddy\ \(deleted\)) red '发现无服务定义的 Caddy 进程，请先确认归属';return 1;; esac
            done
        fi
        rc-update del caddy >/dev/null 2>&1 || true
    else
        if systemctl cat caddy.service >/dev/null 2>&1; then systemctl disable --now caddy >/dev/null 2>&1 || return 1; fi
    fi
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
fetch_latest_script() {
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh -o "$1"
}
validate_script_download() {
    local file=$1 version
    bash -n "$file" || return 1
    version=$(sed -nE 's/^SCRIPT_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$file")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    # 不 source/执行下载内容；这里只检查格式，来源信任仍依赖官方仓库 HTTPS。
    grep -q '^# Xray-2go ' "$file" && grep -q '^main() {' "$file" && grep -q '^upgrade_installation() (' "$file" && grep -Fq 'SERVICES=(xray2go-core xray2go-tunnel xray2go-sub xray2go-sync)' "$file" || return 1
    printf '%s\n' "$version"
}
online_update() {
    [ -f "$work_dir/.installed" ] && [ -s "$work_dir/runtime.sh" ] || { red '请先安装或迁移本项目，再在线更新。';return 1; }
    local staged result=0
    staged=$(mktemp "$work_dir/.online-update.XXXXXX") || return 1
    chmod 600 "$staged"
    if ! fetch_latest_script "$staged";then rm -f "$staged";red '下载失败，原脚本未变。';return 1;fi
    with_lock apply_script_update "$staged" || result=$?
    rm -f "$staged"
    return "$result"
}
refresh_script_on_launch() {
    # 只在无参数、外部脚本启动且本项目已安装时保存；不触碰旧版迁移或未安装机器。
    [ -f "$work_dir/.installed" ] && [ -s "$work_dir/runtime.sh" ] || return 0
    local source_path installed_path staged result=0
    source_path=$(readlink -f "$SELF") || return 1
    installed_path=$(readlink -f "$work_dir/runtime.sh") || return 1
    [ "$source_path" != "$installed_path" ] || return 0
    staged=$(mktemp "$work_dir/.launch-update.XXXXXX") || return 1
    chmod 600 "$staged"
    if ! cp "$SELF" "$staged";then rm -f "$staged";red '无法保存当前脚本，原脚本未变。';return 1;fi
    with_lock apply_script_update "$staged" launch || result=$?
    rm -f "$staged"
    return "$result"
}
apply_script_update() {
    local candidate=$1 context=${2:-online} version current newer backup
    version=$(validate_script_download "$candidate") || { red '下载内容不是有效的 Xray-2go 脚本，原脚本未变。';return 1; }
    current=$(sed -nE 's/^SCRIPT_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$work_dir/runtime.sh")
    [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { red '无法确认本机版本，停止更新。';return 1; }
    newer=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)
    [ "$newer" = "$version" ] || { red "远端版本 $version 比本机 $current 旧，拒绝降级。";return 1; }
    if cmp -s "$candidate" "$work_dir/runtime.sh";then green "本机已经是最新脚本 v$current，无需更新。";return 0;fi
    mkdir -p "$work_dir/backups" || return 1
    backup=$(mktemp -d "$work_dir/backups/script-update-XXXXXX") || return 1
    chmod 700 "$work_dir/backups" "$backup"
    cp -p "$work_dir/runtime.sh" "$backup/runtime.sh" || return 1
    chmod 700 "$candidate"
    mv -f "$candidate" "$work_dir/runtime.sh" || return 1
    green "脚本已从 v$current 更新到 v$version。配置和内核未变，服务未重启。"
    if [ "$context" = launch ];then green '已同步本机脚本，正在进入当前新版菜单。'
    else green '请退出当前菜单后重新运行 2go；需要重建服务时再选择“修复当前服务”。';fi
}
install_runtime_copy() {
    if [ "$SELF" != "$work_dir/runtime.sh" ]; then cp "$SELF" "$work_dir/runtime.sh"; fi
    chmod 700 "$work_dir/runtime.sh"
    local entry
    entry=$(mktemp "${shortcut_path}.XXXXXX") || return 1
    printf '#!/bin/sh\nexec /bin/bash /etc/xray/runtime.sh "$@"\n' > "$entry"
    chmod 755 "$entry"; mv -f "$entry" "$shortcut_path"
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
        elif [ "$s" = xray2go-tunnel ] && ! any_argo_protocol; then service_disable "$s"
        else service_enable "$s" || return 1; fi
    done
}
start_services() {
    local s old action
    for s in "${SERVICES[@]}"; do
        if [ "$s" = xray2go-sub ] && ! jq -e .subscription_enabled "$state_file" >/dev/null; then continue; fi
        if [ "$s" = xray2go-tunnel ] && ! any_argo_protocol; then continue; fi
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
        else rm -f "$work_dir/$f"; fi
    done
    if [ -e "$b/shortcut.before" ] || [ -L "$b/shortcut.before" ]; then
        rm -f "$shortcut_path"; cp -a "$b/shortcut.before" "$shortcut_path"
    elif [ -f "$shortcut_path" ] && grep -Fq /etc/xray/runtime.sh "$shortcut_path"; then rm -f "$shortcut_path"; fi
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
    local upgrade_stage='导入原安装状态'
    trap 'r=$?; if [ "$r" -ne 0 ]; then red "升级失败阶段：$upgrade_stage（退出码 $r）"; rollback_upgrade "$backup"; fi' EXIT
    load_legacy_state || return 1
    if [ -n "${NODE_NAME:-}" ];then state_string name "$NODE_NAME"
    elif [ "$(state name)" = "$(hostname)" ];then state_string name "$(resolve_node_name)";fi
    upgrade_stage='校验 Xray 配置'
    # 只校正旧 RAW 入站/flow；不改 UUID、私钥、短 ID、端口和 SNI。
    local c; c=$(mktemp "$work_dir/.config.XXXXXX")
    jq '(.inbounds[]|select(.protocol=="vless" and .streamSettings.security=="reality" and (.streamSettings.network=="raw" or .streamSettings.network=="tcp" or .streamSettings.network=="grpc"))) |= (del(.streamSettings.grpcSettings) | .streamSettings.network="raw" | (.settings.clients[].flow)="xtls-rprx-vision")' "$config_dir" > "$c"
    validate_xray_config "$c" || { rm -f "$c"; return 1; }; chmod 600 "$c"; mv "$c" "$config_dir"
    chmod 711 "$work_dir"
    upgrade_stage='生成订阅和校验 Nginx 配置'
    generate_subscription || return 1
    write_nginx_config && nginx -t -c "$work_dir/nginx.conf" >/dev/null 2>&1 || return 1
    # 到这里配置已全部验证，才交接监听端口。
    upgrade_stage='交接旧 Caddy 服务'
    if [ ! -f "$work_dir/.caddy-retired" ] && [ -f /etc/caddy/Caddyfile ]; then
        check_caddy_owned /etc/caddy/Caddyfile || { red '检测到共享或未知 Caddy 配置，拒绝自动交接';return 1; }
        stop_owned_caddy || return 1
    fi
    upgrade_stage='清理已确认归属的旧服务'
    legacy_retire || return 1
    upgrade_stage='更新本机脚本和服务定义'
    install_runtime_copy || return 1
    configure_services || return 1
    upgrade_stage='启动服务和验证订阅'
    start_services || { red '迁移启动未通过，请保留备份并检查服务'; return 1; }
    touch "$work_dir/.installed"
    trap - EXIT
    green '迁移完成：原订阅端口、路径和认证已保留。NAT 映射无需改变。'
)

validate_install_ports() {
    local p
    [ "$(printf '%s\n' "$@" 3001 3002 3003 | sort -u | wc -l)" -eq 7 ] || { red '所选端口冲突，3001–3003 为内部回落保留端口';return 1; }
    for p in "$@" 3001 3002 3003;do port_available "$p" || { red '安装端口无效或已占用';return 1; };done
}
cleanup_failed_install() {
    [ -f "$work_dir/.installing" ] || return 1
    local s f retired
    for s in xray2go-sync xray2go-sub xray2go-tunnel xray2go-core;do
        if is_openrc;then f="$init_dir/$s";else f="$systemd_dir/$s.service";fi
        if [ -f "$f" ];then
            grep -Fq 'Managed by shadowxhero/xray-2go' "$f" || return 1
            service_action "$s" stop || true
            stop_owned_processes "${s#xray2go-}" || return 1
            service_disable "$s";rm -f "$f"
        fi
    done
    if [ -e "$work_dir/shortcut-before" ] || [ -L "$work_dir/shortcut-before" ];then
        rm -f "$shortcut_path";cp -a "$work_dir/shortcut-before" "$shortcut_path"
    elif [ -f "$shortcut_path" ] && grep -Fq /etc/xray/runtime.sh "$shortcut_path";then rm -f "$shortcut_path";fi
    [ -d "$archive_root" ] && [ ! -L "$work_dir" ] || return 1
    retired=$(mktemp -d "$archive_root/xray2go-failed-install-XXXXXX") || return 1
    chmod 700 "$retired";rmdir "$retired";mv "$work_dir" "$retired";chmod 700 "$retired"
    red '安装未完成，已停止本次服务并归档半安装文件，可重新安装。'
}
install_fresh() (
    set -e
    [ ! -e "$config_dir" ] || { red '已有配置，请使用 --upgrade，避免覆盖认证信息'; return 1; }
    install_dependencies || return 1
    mkdir -p "$work_dir"; chmod 711 "$work_dir"; umask 077
    local arch xr uuid private pub output subp rawp xhp ap name server
    case $(uname -m) in
        x86_64|amd64) arch=amd64; xr=64;; aarch64|arm64) arch=arm64; xr=arm64-v8a;;
        i386|i686) arch=386; xr=32;; armv7l) arch=arm; xr=arm32-v7a;; *) red '不支持的 CPU 架构';return 1;;
    esac
    subp=${PORT:-$(shuf -i 10000-60000 -n 1)}; rawp=${RAW_PORT:-$((subp+1))}; xhp=${XHTTP_PORT:-$((subp+2))}; ap=${ARGO_PORT:-8080}
    validate_install_ports "$subp" "$rawp" "$xhp" "$ap" || return 1
    local s
    for s in "${SERVICES[@]}";do [ ! -e "$init_dir/$s" ] && [ ! -e "$systemd_dir/$s.service" ] || { red '存在同名服务，拒绝覆盖';return 1; };done
    touch "$work_dir/.installing"
    if [ -e "$shortcut_path" ] || [ -L "$shortcut_path" ];then cp -a "$shortcut_path" "$work_dir/shortcut-before";fi
    trap 'r=$?; if [ "$r" -ne 0 ];then cleanup_failed_install || true;fi' EXIT
    curl -fSL --retry 2 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-'"$xr"'.zip' -o "$work_dir/core.zip" || return 1
    unzip -oq "$work_dir/core.zip" xray -d "$work_dir" || return 1
    curl -fSL --retry 2 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-'"$arch" -o "$work_dir/argo" || return 1
    chmod 700 "$work_dir/xray" "$work_dir/argo"; rm -f "$work_dir/core.zip"
    uuid=${UUID:-$(random_uuid)}; output=$("$work_dir/xray" x25519) || return 1
    private=$(awk '/^PrivateKey/{print $NF}' <<< "$output"); [ -n "$private" ] || return 1
    server=${SERVER_IP:-$(get_realip)}; server=$(normalize_host "$server"); valid_host "$server" || return 1
    name=$(resolve_node_name)
    jq -n --arg id "$uuid" --arg private "$private" --argjson raw "$rawp" --argjson xh "$xhp" --argjson ap "$ap" '{log:{access:"/dev/null",error:"/dev/null",loglevel:"none"},inbounds:[{tag:"argo-entry",listen:"127.0.0.1",port:$ap,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none",fallbacks:[{dest:3001},{path:"/vless-argo",dest:3002},{path:"/vmess-argo",dest:3003}]},streamSettings:{network:"raw"}},{tag:"fallback",listen:"127.0.0.1",port:3001,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"raw"}},{tag:"vless-ws",listen:"127.0.0.1",port:3002,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"ws",wsSettings:{path:"/vless-argo"}}},{tag:"vmess-ws",listen:"127.0.0.1",port:3003,protocol:"vmess",settings:{clients:[{id:$id}]},streamSettings:{network:"ws",wsSettings:{path:"/vmess-argo"}}},{tag:"raw-reality",port:$raw,protocol:"vless",settings:{clients:[{id:$id,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{target:"www.iij.ad.jp:443",serverNames:["www.iij.ad.jp"],privateKey:$private,shortIds:[""]}}},{tag:"xhttp-reality",port:$xh,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:{network:"xhttp",security:"reality",realitySettings:{target:"www.nazhumi.com:443",serverNames:["www.nazhumi.com"],privateKey:$private,shortIds:[""]}}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$config_dir"
    validate_xray_config "$config_dir" || return 1
    jq -n --arg name "$name" --arg server "$server" --arg cdn "${CFIP:-cdns.doon.eu.org}" --argjson cp "${CFPORT:-443}" --arg path "$(random_path)" --argjson sp "$subp" --argjson ap "$ap" '{version:2,name:$name,server:$server,cdn:$cdn,cdn_port:$cp,subscription_port:$sp,subscription_path:$path,subscription_enabled:true,tunnel_mode:"quick",tunnel_domain:"",argo_port:$ap}' > "$state_file"
    protocols_state_set "${ALL_PROTOCOLS[@]}" || return 1
    # 只装部分协议时（PROTOCOLS=raw-reality,vless-argo），安装阶段就把其余入站裁掉。
    if [ -n "${PROTOCOLS:-}" ]; then apply_protocols_unlocked "$PROTOCOLS" || return 1; fi
    generate_subscription; write_nginx_config
    nginx -t -c "$work_dir/nginx.conf" >/dev/null 2>&1 || return 1
    install_runtime_copy && configure_services && start_services || return 1
    touch "$work_dir/.installed";rm -f "$work_dir/.installing"
    trap - EXIT
    green '安装完成。NAT 机器须映射订阅和两个直连 TCP 端口；Argo 无需映射内部端口。'
    local wait_domain
    for wait_domain in {1..10};do sync_subscription || true;[ -n "$(state tunnel_domain || true)" ] && break;sleep 1;done
    if [ -z "$(state tunnel_domain || true)" ];then menu_color 33 '临时域名尚未取得，两个 Argo 节点暂不可用；同步器取得后会自动更新。';fi
    show_nodes
)

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
    # 新隧道尚未拿到域名，旧域名的失败计数必须归零，否则会立刻被判死再重启一次。
    rm -f "$work_dir/.health-fails"
    service_action xray2go-tunnel restart
}

# 临时隧道（quick）会被 Cloudflare 单方面回收：cloudflared 收到 "Unauthorized: Tunnel not found"
# 后不退出、一直重连，respawn 不触发，argo.log 里也不会出现新域名，订阅于是长期指向一个
# DNS 已经消失的域名。这里按日志判据做存活探测（不取锁、不发网络请求、不增加常驻内存），
# 连续失败才重启隧道重新申请域名。
tunnel_probe() {
    local domain=$1 log="$work_dir/argo.log"
    [ -n "$domain" ] || return 1
    [ -f "$log" ] || return 1
    # 纯日志判据，不发任何网络请求：tunnel-worker 启动时会截断日志，所以这里只看本次进程。
    # 隧道被回收后 cloudflared 会持续写 "Tunnel not found"；注册成功则写
    # "Registered tunnel connection"。日志极小（几十行），grep 的进程开销远低于 128MB 机器上
    # 再 fork 一个 curl 的瞬时峰值。
    grep -q 'Tunnel not found' "$log" 2>/dev/null && return 1
    grep -q 'Registered tunnel connection' "$log" 2>/dev/null || return 1
    return 0
}
tunnel_health() {
    [ "$(state tunnel_mode)" = quick ] || return 0
    local domain now ts=0 last=0 fails=0
    domain=$(state tunnel_domain) || return 0
    [ -n "$domain" ] || return 0
    now=$(date +%s)
    # 探测节流 60 秒，避免同步器每一轮都发外部请求。
    [ ! -f "$work_dir/.health-ts" ] || read -r ts < "$work_dir/.health-ts"
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    ((now-ts>=60)) || return 0
    # 隧道刚重启时旧域名必然不通，留 180 秒等 cloudflared 拿到新域名再判定。
    [ ! -f "$work_dir/last-renew" ] || read -r last < "$work_dir/last-renew"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    ((now-last>=180)) || return 0
    printf '%s\n' "$now" > "$work_dir/.health-ts"
    if tunnel_probe "$domain"; then rm -f "$work_dir/.health-fails"; return 0; fi
    # 用户主动停止隧道（切换固定隧道、临时关闭）时不自动拉起，与手动 stop 的约定一致。
    service_status xray2go-tunnel || { rm -f "$work_dir/.health-fails"; return 0; }
    [ ! -f "$work_dir/.health-fails" ] || read -r fails < "$work_dir/.health-fails"
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    fails=$((fails+1)); printf '%s\n' "$fails" > "$work_dir/.health-fails"
    ((fails>=3)) || return 0
    rm -f "$work_dir/.health-fails"
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
    if [ -f "$shortcut_path" ] && grep -Fq /etc/xray/runtime.sh "$shortcut_path"; then rm -f "$shortcut_path"; fi
    local retired="$archive_root/xray2go-uninstalled-$(date +%Y%m%d-%H%M%S)"
    [ "$(readlink -f "$work_dir")" = /etc/xray ] && [ ! -e "$retired" ] || return 1
    mv "$work_dir" "$retired"; chmod 700 "$retired"
    green '服务、开机项已移除；配置和密钥已归档到 root 目录，不再有后台进程。'
}
subscription_url() {
    printf 'http://%s:%s/%s' "$(host_uri "$(state server)")" "$(state subscription_port)" "$(state subscription_path)"
}
show_nodes() {
    [ -f "$client_dir" ] || { red '节点信息文件不存在，请先安装或修复。';return 1; }
    local line link
    menu_color 32 '=== 当前节点信息 ==='
    printf '\n'
    while IFS= read -r line || [ -n "$line" ];do
        [ -n "$line" ] || continue
        menu_color 35 "$line";printf '\n'
    done < "$client_dir"
    menu_separator
    menu_color 32 '=== 订阅链接 ==='
    menu_color 32 'V2rayN / Shadowrocket 等兼容客户端：'
    link=$(subscription_url);menu_color 35 "$link";printf '\n'
    if [ -x "$work_dir/qrencode" ];then "$work_dir/qrencode" "$link" || menu_color 33 '二维码生成失败，仍可复制订阅地址。'
    elif command_exists qrencode;then qrencode -t ANSIUTF8 "$link" || menu_color 33 '二维码生成失败，仍可复制订阅地址。';fi
    if ! jq -e .subscription_enabled "$state_file" >/dev/null;then menu_color 33 '当前订阅服务已关闭，开启后才能下载。';fi
    menu_color 33 'NAT：订阅端口必须在服务商面板映射；本机 HTTP 成功不代表公网已映射。'
    menu_color 33 'RAW/XHTTP 请使用支持对应传输及新版 REALITY 的客户端内核。'
}
menu_color() { printf '\033[1;%sm%s\033[0m\n' "$1" "$2"; }
menu_separator() { menu_color 36 '----------------------------------------'; }
project_service_exists() {
    [ -f "$init_dir/$1" ] || [ -f "$systemd_dir/$1.service" ]
}
installation_state() {
    local s complete=true found=false
    if [ -f "$work_dir/.installed" ]; then
        [ -x "$work_dir/xray" ] && [ -s "$config_dir" ] && [ -s "$state_file" ] && [ -s "$client_dir" ] || complete=false
        for s in "${SERVICES[@]}"; do project_service_exists "$s" || complete=false;done
        if [ "$complete" = true ];then printf 'installed\n';else printf 'partial\n';fi
        return
    fi
    if [ -x "$work_dir/xray" ] && [ -s "$config_dir" ] && [ -s "$client_dir" ];then
        for s in xray tunnel;do
            if legacy_owned "$init_dir/$s" || legacy_owned "$systemd_dir/$s.service";then printf 'legacy\n';return;fi
        done
    fi
    for s in "${SERVICES[@]}";do project_service_exists "$s" && found=true;done
    if [ "$found" = true ] || [ -e "$config_dir" ] || [ -e "$state_file" ] || [ -e "$work_dir/.installing" ];then printf 'partial\n'
    elif [ -f "$argox_config" ];then printf 'foreign\n'
    else printf 'absent\n';fi
}
show_status() {
    local status s label
    status=$(installation_state)
    menu_color 35 "=== Xray-2go v$SCRIPT_VERSION ==="
    case "$status" in
        installed) menu_color 32 '安装状态：已安装';;
        legacy) menu_color 33 '安装状态：旧版安装，请先迁移';;
        partial) menu_color 33 '安装状态：安装不完整，请检查后修复/迁移';;
        foreign) menu_color 33 '安装状态：本项目未安装；检测到 ArgoX，请勿覆盖其配置或服务';;
        absent) menu_color 33 '安装状态：未安装';;
    esac
    if [ "$status" = installed ] || [ "$status" = partial ];then
        for s in "${SERVICES[@]}";do
            case "$s" in xray2go-core) label=Xray;;xray2go-tunnel) label=Argo;;xray2go-sub) label=Nginx订阅;;xray2go-sync) label=订阅同步;;esac
            if ! project_service_exists "$s";then menu_color 33 "$label：未安装"
            elif service_status "$s";then menu_color 32 "$label：运行中"
            else menu_color 31 "$label：已停止";fi
        done
    fi
}
menu_option_allowed() {
    local status=$1 choice=$2
    case "$choice" in 0|h|H) return 0;;esac
    case "$status:$choice" in
        absent:1|legacy:2|installed:2|installed:3|installed:4|installed:5|installed:6|installed:7|installed:8|installed:9|installed:10|installed:11|installed:12|installed:13|installed:14|installed:15|installed:16|installed:17|installed:18) return 0;;
        partial:2) [ -x "$work_dir/xray" ] && [ -s "$config_dir" ] && [ -s "$client_dir" ];return $?;;
        *) return 1;;
    esac
}
render_menu() {
    local status
    status=$(installation_state)
    show_status; menu_separator
    case "$status" in
        absent) menu_color 32 '1. 新安装';;
        legacy) menu_color 32 '2. 升级/从 Caddy 迁移（保留配置）';;
        partial)
            if menu_option_allowed partial 2;then menu_color 33 '2. 修复/迁移现有安装（先备份）';else menu_color 33 '配置或内核缺失，暂不提供修改/卸载入口，请先检查安装记录。';fi;;
        installed)
            menu_color 32 '2. 在线更新脚本（不重启服务）'
            menu_color 32 '18. 修复当前服务（本机版本，保留配置）'
            menu_color 32 '3. 查看节点与订阅'
            menu_color 32 '4. 协议管理（增删节点）'
            menu_color 32 '5. 修改节点名称'
            menu_separator
            menu_color 32 '6. 修改 RAW 端口'
            menu_color 32 '7. 修改 XHTTP 端口'
            menu_color 32 '8. 修改订阅端口'
            menu_color 32 '9. 订阅启用/关闭'
            menu_separator
            menu_color 32 '10. 服务启停'
            menu_color 32 '11. 隧道管理'
            menu_color 32 '12. 修改 UUID'
            menu_color 32 '13. 修改 Reality SNI'
            menu_color 32 '14. 修改 Argo 优选地址/端口'
            menu_color 32 '15. 修改直连 IP（IPv4/IPv6）'
            menu_color 32 '16. 修改 Argo 内部端口'
            menu_separator
            menu_color 31 '17. 卸载';;
    esac
    menu_separator
    menu_color 35 'h. 帮助'
    menu_color 31 '0. 退出'
    menu_separator
}
# 2026-11-18：合并 eooce/Sing-box 与 fscarmen/ArgoX 预设，经两个网络环境的 TLS/WebSocket 转发验证。
EDGE_PRESETS=(cf.090227.xyz cf.877774.xyz cf.877771.xyz cdns.doon.eu.org time.is skk.moe ip.sb xn--b6gac.eu.org)
SNI_PRESETS=(www.iij.ad.jp www.nazhumi.com bgk.jp www.joom.com www.stengg.com)
random_port_candidate() { shuf -i 2000-65000 -n 1; }
port_candidate_usable() {
    local p=$1 current=${2:-0}
    valid_port "$p" || return 1
    p=$((10#$p))
    [[ "$p" != 3001 && "$p" != 3002 && "$p" != 3003 ]] || return 1
    if [ "$p" = "$current" ];then return 0;fi
    if jq -e --argjson p "$p" 'any(.inbounds[]; .port==$p)' "$config_dir" >/dev/null 2>&1;then return 1;fi
    [ "$p" != "$(state subscription_port)" ] || return 1
    [ "$p" != "$(state argo_port)" ] || return 1
    port_available "$p"
}
prompt_port() {
    local label=$1 current=${2:-0} value n
    while true;do
        reading "$label（1–65535；回车随机生成）：" value || return 1
        if [ -z "$value" ];then
            for ((n=0;n<100;n++));do
                value=$(random_port_candidate)
                if [ "$value" != "$current" ] && port_candidate_usable "$value" "$current";then
                    REPLY=$((10#$value));menu_color 32 "随机选择端口：$REPLY";return 0
                fi
            done
            red '尝试 100 次仍未找到可用端口，请手动输入。';return 1
        fi
        if port_candidate_usable "$value" "$current";then REPLY=$((10#$value));return 0;fi
        red '端口无效、已占用或被当前配置保留，请重新输入。'
    done
}
interactive_port() {
    local kind=$1 current selected
    case "$kind" in
        raw|xhttp) current=$(jq -er --arg n "$kind" '.inbounds[]|select(.streamSettings.security=="reality" and (.streamSettings.network==$n or ($n=="raw" and .streamSettings.network=="tcp")))|.port' "$config_dir") || return 1;;
        sub) current=$(state subscription_port);;
        argo) current=$(state argo_port);;
        *) return 1;;
    esac
    menu_color 32 "当前端口：$current"
    prompt_port '请输入新端口' "$current" || return 1;selected=$REPLY
    case "$kind" in raw|xhttp) set_direct_port "$kind" "$selected";;sub) set_subscription_port "$selected";;argo) set_argo_port "$selected";;esac || { red '端口修改失败，请检查上方提示。';return 1; }
    green "端口已设置为 $selected，原认证信息不变。"
    if [ "$kind" = sub ];then menu_color 35 "$(subscription_url)";else show_nodes;fi
    [ "$kind" = argo ] || menu_color 33 'NAT 机器请确认此端口在服务商允许范围内，并配置对应 TCP 映射。'
}
parse_edge_input() {
    local value=$1 host port=443 index
    if [ -z "$value" ];then EDGE_HOST=$(state cdn);EDGE_PORT=$(state cdn_port);return 0;fi
    if [[ "$value" =~ ^[0-9]{1,2}$ ]];then
        index=$((10#$value));((index>=1 && index<=${#EDGE_PRESETS[@]})) || return 1
        host=${EDGE_PRESETS[$((index-1))]}
    elif [[ "$value" =~ ^\[([0-9a-fA-F:]+)\](:([0-9]+))?$ ]];then
        host=${BASH_REMATCH[1]};port=${BASH_REMATCH[3]:-443}
    elif [[ "$value" != *:* ]];then host=$value
    elif [[ "$value" =~ ^([^:]+):([0-9]+)$ ]];then host=${BASH_REMATCH[1]};port=${BASH_REMATCH[2]}
    else return 1;fi
    valid_host "$host" && valid_port "$port" || return 1
    if [[ "$host" == *:* ]];then valid_ipv6 "$host" || return 1
    elif [[ "$host" =~ ^[0-9.]+$ ]];then valid_ipv4 "$host" || return 1;fi
    [[ "$host" != *..* ]] || return 1
    EDGE_HOST=$host;EDGE_PORT=$((10#$port))
}
interactive_cdn() {
    local value i
    menu_color 32 '=== Argo 优选地址 ==='
    menu_color 33 "当前：$(host_uri "$(state cdn)"):$(state cdn_port)"
    for i in "${!EDGE_PRESETS[@]}";do menu_color 32 "$((i+1)). ${EDGE_PRESETS[$i]}:443";done
    menu_color 33 '预设为测试当时可用，不代表所有线路最快；选择后仍需客户端实测。'
    while true;do
        reading '输入编号/域名/IPv4/[IPv6]:端口（回车保持当前）：' value || return 1
        if parse_edge_input "$value";then break;fi
        red '地址格式错误，请重新输入；IPv6 带端口时必须使用方括号。'
    done
    set_cdn "$EDGE_HOST" "$EDGE_PORT" || { red '优选地址修改失败。';return 1; }
    green "两个 Argo 节点优选地址已更新为 $(host_uri "$EDGE_HOST"):$EDGE_PORT"
    show_nodes
}
interactive_sni() {
    local choice network value i host
    menu_color 32 '=== 修改 Reality SNI ==='
    menu_color 32 '1. RAW-Reality';menu_color 32 '2. XHTTP-Reality';menu_color 35 '0. 返回'
    reading '选择：' choice || return 1
    case "$choice" in 1) network=raw;;2) network=xhttp;;0) return 0;;*) red '无效选项';return 0;;esac
    for i in "${!SNI_PRESETS[@]}";do menu_color 32 "$((i+1)). ${SNI_PRESETS[$i]}";done
    menu_color 33 '这些是域名候选，不保证都适合当前机房；目标需要支持 TLS 1.3。'
    reading '编号或自定义 SNI（回车默认 1）：' value || return 1
    value=${value:-1}
    if [[ "$value" =~ ^[0-9]{1,2}$ ]];then
        ((10#$value>=1 && 10#$value<=${#SNI_PRESETS[@]})) || { red '编号无效';return 1; }
        host=${SNI_PRESETS[$((10#$value-1))]}
    else host=$value;fi
    set_sni "$network" "$host" || { red 'SNI 修改失败。';return 1; }
    green "$network 的 SNI 已更新为 $host";show_nodes
}
interactive_services() {
    local choice name action
    menu_color 32 '=== 服务管理 ==='
    menu_color 32 '1. Xray';menu_color 32 '2. Argo';menu_color 32 '3. Nginx 订阅';menu_color 32 '4. 订阅同步';menu_color 35 '0. 返回'
    reading '选择服务：' choice || return 1
    case "$choice" in 1) name=core;;2) name=tunnel;;3) name=sub;;4) name=sync;;0) return 0;;*) red '无效选项';return 0;;esac
    menu_color 32 '1. 启动';menu_color 32 '2. 停止';menu_color 32 '3. 重启';menu_color 35 '0. 返回'
    reading '选择操作：' choice || return 1
    case "$choice" in 1) action=start;;2) action=stop;;3) action=restart;;0) return 0;;*) red '无效选项';return 0;;esac
    if [ "$name" = sub ] && [ "$action" != stop ] && ! jq -e .subscription_enabled "$state_file" >/dev/null;then
        red '订阅已关闭，请通过“管理订阅”开启，避免状态与自启配置不一致。';return 0
    fi
    service_action "xray2go-$name" "$action" || { red '服务操作失败。';return 1; }
    green "服务 $name 已执行 $action。主动停止不会被同步器拉起。"
}
interactive_subscription() {
    local choice
    menu_color 32 '=== 管理订阅 ==='
    menu_color 32 '1. 开启订阅（保留原路径）';menu_color 32 '2. 关闭订阅';menu_color 32 '3. 修改订阅端口';menu_color 32 '4. 重启订阅服务';menu_color 35 '0. 返回'
    reading '选择：' choice || return 1
    case "$choice" in
        1) set_subscription_enabled true && { green '订阅已开启。';menu_color 35 "$(subscription_url)"; };;
        2) set_subscription_enabled false && green '订阅已关闭并取消订阅服务自启。';;
        3) interactive_port sub;;
        4) if ! jq -e .subscription_enabled "$state_file" >/dev/null;then red '订阅已关闭，请先选择开启订阅。';return 0;fi
           service_action xray2go-sub restart && subscription_probe && green '订阅服务已重启并通过本机内容检查。';;
        0) return 0;;*) red '无效选项，未改变订阅状态。';;
    esac
}
interactive_tunnel() {
    local choice domain file
    menu_color 32 '=== Argo 隧道管理 ==='
    menu_color 33 "当前模式：$(state tunnel_mode)，本机回源端口：$(state argo_port)"
    menu_color 32 '1. 启动隧道';menu_color 32 '2. 停止隧道';menu_color 32 '3. 重启隧道';menu_color 32 '4. 添加/更换固定隧道';menu_color 32 '5. 切换临时隧道';menu_color 32 '6. 重新获取临时域名';menu_color 35 '0. 返回'
    reading '选择：' choice || return 1
    case "$choice" in
        1) service_action xray2go-tunnel start;;2) service_action xray2go-tunnel stop;;3) service_action xray2go-tunnel restart;;
        4)
            menu_color 32 '1. Token 文件';menu_color 32 '2. JSON 文件';reading '凭据类型：' choice || return 1
            case "$choice" in 1) choice=token;;2) choice=json;;*) red '无效选项';return 0;;esac
            reading '固定隧道域名：' domain || return 1;reading '服务器上凭据文件的路径（不要粘贴密钥）：' file || return 1
            set_tunnel "$choice" "$domain" "$file";;
        5) set_tunnel quick;;6) renew_tunnel;;0) return 0;;*) red '无效选项';return 0;;
    esac || { red '隧道操作失败，未确认成功。';return 1; }
    green '隧道操作已提交。若重新申请临时域名，同步器会自动更新两个 Argo 节点；Cloudflare 限流时不会立即恢复。'
}
# 新安装前询问要装哪些协议，返回逗号分隔列表；直接回车=全部四个。
ask_install_protocols() {
    local i input list
    menu_color 32 '选择要安装的协议（编号可连写，例如 13；直接回车=全部四个）：'
    i=1
    for p in "${ALL_PROTOCOLS[@]}"; do
        menu_color 32 "  $i. $(protocol_label "$p")"
        i=$((i+1))
    done
    while true; do
        reading '请选择：' input || return 1
        if list=$(protocols_from_digits "$input"); then
            printf '%s\n' "$list"
            return 0
        fi
        red '无效输入：只能输入 1-4 的组合，例如 13 或 1234。'
    done
}
interactive_protocols() {
    local choice i p cur next
    while true; do
        menu_color 32 '=== 协议管理 ==='
        i=1
        for p in "${ALL_PROTOCOLS[@]}"; do
            if protocol_enabled "$p"; then
                menu_color 32 "$i. [已启用] $(protocol_label "$p")"
            else
                menu_color 33 "$i. [已关闭] $(protocol_label "$p")"
            fi
            i=$((i+1))
        done
        menu_color 35 '0. 返回'
        menu_color 33 '切换会重建 Xray 配置并重启 core；两个 Argo 协议都关闭时连带停止 cloudflared。'
        reading '选择要切换的协议：' choice || return 1
        case "$choice" in
            0) return 0 ;;
            1|2|3|4)
                p="${ALL_PROTOCOLS[$((choice-1))]}"
                cur=$(protocols_current)
                if protocol_listed "$p" "$cur"; then
                    next=$(printf '%s\n' "$cur" | grep -vx "$p" | tr '\n' ',' | sed 's/,$//')
                    [ -n "$next" ] || { red '至少要保留一个协议。'; continue; }
                else
                    next=$(printf '%s\n%s\n' "$cur" "$p" | tr '\n' ',' | sed 's/,$//')
                fi
                if apply_protocols "$next"; then
                    green "当前协议：$(protocols_joined)"
                    show_nodes
                else
                    red '协议变更失败，配置已回滚。'
                fi
                ;;
            *) red '无效选项' ;;
        esac
        menu_pause
    done
}
valid_ipv4() {
    local v=$1 a part
    [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a a <<< "$v"
    for part in "${a[@]}";do ((10#$part<=255)) || return 1;done
}
valid_ipv6() {
    local value=$1 compact group count=0 compressed=false
    [[ "$value" =~ ^[0-9a-fA-F:]+$ && "$value" == *:* && "$value" != *:::* ]] || return 1
    [[ "$value" != :* || "$value" == ::* ]] && [[ "$value" != *: || "$value" == *:: ]] || return 1
    compact=${value//:/};[[ "$compact" =~ [1-9a-fA-F] ]] || return 1
    if [[ "$value" == *::* ]];then
        compressed=true;compact=${value/::/X};[[ "$compact" != *::* ]] || return 1
    else [[ "$value" != :* && "$value" != *: ]] || return 1;fi
    local groups=()
    IFS=: read -r -a groups <<< "$value"
    for group in "${groups[@]}";do
        [ -n "$group" ] || continue
        ((${#group}<=4)) || return 1
        count=$((count+1))
    done
    if [ "$compressed" = true ];then ((count<8));else ((count==8));fi
}
fetch_direct_ip() {
    local family=$1 ip trace
    [[ "$family" == 4 || "$family" == 6 ]] || return 1
    ip=$(curl --noproxy '*' "-$family" -fsS --max-time 5 https://api64.ipify.org) || return 1
    if [ "$family" = 4 ];then valid_ipv4 "$ip" || return 1
    else valid_ipv6 "$ip" || return 1;fi
    trace=$(curl --noproxy '*' "-$family" -fsS --max-time 5 https://www.cloudflare.com/cdn-cgi/trace) || { red '无法确认出口是否为 WARP，请改用手动输入实际公网 IP。';return 1; }
    if ! grep -qx 'warp=off' <<< "$trace";then red '检测到 WARP 或无法确认出口，不能自动用作入站 IP。';return 1;fi
    REPLY=$ip
}
interactive_address() {
    local choice value
    menu_color 32 '=== 修改直连节点地址 ==='
    menu_color 32 '1. 自动获取 IPv4';menu_color 32 '2. 自动获取 IPv6';menu_color 32 '3. 手动输入公网 IP';menu_color 35 '0. 返回'
    menu_color 33 '只更新直连节点和订阅显示地址，不改变 Argo 优选入口。'
    reading '选择：' choice || return 1
    case "$choice" in
        1|2) if [ "$choice" = 1 ];then value=4;else value=6;fi;fetch_direct_ip "$value" || { red '获取入站地址失败。';return 1; };value=$REPLY;;
        3) reading '实际公网 IP（不能填 WARP 出口）：' value || return 1;value=$(normalize_host "$value");valid_ipv4 "$value" || valid_ipv6 "$value" || { red 'IP 格式错误';return 1; };;
        0) return 0;;*) red '无效选项';return 0;;
    esac
    set_server_address "$value" || { red '地址修改失败';return 1; };green "直连地址已更新为 $value";show_nodes
}
menu_pause() {
    if [ -t 0 ];then read -n 1 -s -r -p $'\033[1;91m按任意键返回主菜单…\033[0m' || true;printf '\n';fi
}
menu() {
    local choice value network h p mode domain file status
    while true; do
        [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ] || clear
        render_menu
        reading $'\033[1;91m请选择：\033[0m' choice || return 0
        status=$(installation_state)
        if ! menu_option_allowed "$status" "$choice";then
            red '该选项在当前安装状态不可用，请选择屏幕中显示的选项。';menu_pause;continue
        fi
        case "$choice" in
            1) if PROTOCOLS=$(ask_install_protocols);then install_fresh;fi ;;
            2) if [ "$status" = installed ];then
                   if online_update;then green '重新运行 2go 进入更新后的菜单。';return 0;fi
               else upgrade_installation;fi ;;
            18) upgrade_installation ;;
            3) show_nodes ;;
            4) interactive_protocols ;;
            5) reading '基础名：' value && with_lock rename_nodes "$value" && { green '节点名称已更新。';show_nodes; } ;;
            6|7) network=raw; [ "$choice" != 7 ] || network=xhttp; interactive_port "$network" ;;
            8) interactive_port sub ;;
            9) interactive_subscription ;;
            10) interactive_services ;;
            11) interactive_tunnel ;;
            12) reading '新 UUID（留空随机生成）：' value && set_uuid "${value:-$(random_uuid)}" && { green 'UUID 已更新，请更新客户端订阅。';show_nodes; } ;;
            13) interactive_sni ;;
            14) interactive_cdn ;;
            15) interactive_address ;;
            16) interactive_port argo ;;
            17) reading '确认卸载本脚本并归档配置？输入 yes：' value;[ "$value" != yes ] || uninstall_owned ;;
            0) return 0 ;;
            h|H) main --help ;;
            *) red '无效选项' ;;
        esac
        local operation_result=$?
        if [ "$operation_result" -ne 0 ];then red '操作未完成，请检查以上提示；未确认成功前请勿更新客户端配置。';fi
        menu_pause
    done
}
rename_nodes() { [ -n "$1" ] && state_string name "$1" && generate_subscription_unlocked; }
main() {
    case "${1:-}" in
        --version) printf '%s\n' "$SCRIPT_VERSION"; return;;
        -h|--help) printf '2go [-i|--install] [--update] [--repair|--upgrade] [-c|--check] [-r|--restart] [-u|--uninstall] [--sync] [--health] [--protocols [列表]] [--version]\n--update 下载并保存 GitHub 最新脚本，不重启服务或更新内核。\n--repair/--upgrade 使用当前运行版本修复或迁移服务，保留配置，可能重启服务。\n--health 探测临时隧道是否还活着，连续 60 秒级失败三次才重启隧道换域名。\n--protocols 查看协议开关；带列表时切换，例如 --protocols raw-reality,vless-argo（可选：%s）。\n' "${ALL_PROTOCOLS[*]}";return;;
    esac
    require_root || return 1
    case "${1:-}" in
        -i|--install|--repair|--upgrade|'') resolve_self || return 1;;
    esac
    case "${1:-}" in
        -i|--install) install_fresh;;
        --update) online_update;;
        --repair|--upgrade) upgrade_installation;;
        -c|--check) show_nodes;;
        -r|--restart) renew_tunnel;;
        -u|--uninstall) uninstall_owned;;
        --sync) sync_subscription;;
        --protocols)
            if [ -n "${2:-}" ]; then apply_protocols "$2"
            else
                [ -f "$work_dir/.installed" ] || { red '尚未安装。'; return 1; }
                while IFS= read -r p; do
                    [ -n "$p" ] || continue
                    if protocol_enabled "$p"; then printf '已启用\t%s\t%s\n' "$p" "$(protocol_label "$p")"
                    else printf '已关闭\t%s\t%s\n' "$p" "$(protocol_label "$p")"; fi
                done <<< "$(printf '%s\n' "${ALL_PROTOCOLS[@]}")"
            fi ;;
        --health) tunnel_health;;
        --tunnel-worker) tunnel_worker;;
        '') refresh_script_on_launch && menu;;
        *) red '未知参数，请用 --help';return 1;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
