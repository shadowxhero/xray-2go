# Xray-2go v2.0.4

基于 [eooce/xray-2go](https://github.com/eooce/xray-2go)，保留四协议：

- VLESS RAW + REALITY + Vision
- VLESS XHTTP + REALITY（不启用 Vision）
- VLESS WebSocket + Argo
- VMess WebSocket + Argo（AES-128-GCM）

## 新安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh)
```

菜单恢复彩色分组并按安装状态显示：未安装时只有安装/帮助/退出；旧版显示迁移；新版安装完整后才显示节点和服务管理。服务区分未安装、运行中、已停止，配置缺失会显示安装不完整。检测到 ArgoX 时提示避免覆盖，不将它视为本项目安装。

菜单选择「新安装」。也可无交互安装：

```bash
PORT=43013 RAW_PORT=43011 XHTTP_PORT=43012 NODE_NAME='美国三网优化 50M' \
  bash <(curl -fsSL https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh) --install
```

`PORT` 是订阅端口；未设置 `RAW_PORT`、`XHTTP_PORT` 时分别使用 `PORT+1`、`PORT+2`。`ARGO_PORT` 默认 8080，仅供本机 cloudflared 回源。支持 `CFIP`、`CFPORT`、`UUID`、`SERVER_IP` 和 `NODE_NAME`。

**NAT 服务器必须在服务商面板配置端口映射。** 订阅和两个直连节点使用 TCP。修改机器内的监听端口并不会自动创建公网映射；Argo 内部端口不需要映射。

## 原安装升级 / Caddy 迁移

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh) --upgrade
```

- 先备份，再检查 Xray、Nginx 配置，最后交接端口。
- 保留订阅端口、路径、UUID、REALITY 私钥/短 ID/SNI、Argo 优选地址及固定 JSON/Token 隧道。
- 旧 gRPC REALITY 节点转换为 RAW + Vision，原端口不变，客户端须更新订阅。
- 四节点分别命名为 `基础名-RAW-Reality`、`基础名-XHTTP-Reality`、`基础名-VLESS-Argo`、`基础名-VMess-Argo`。可用 `NODE_NAME` 指定新基础名。
- Caddy 只有被确认是旧脚本的单订阅站点才会停止；不擅自删除 Caddy 软件包或其他网站。
- Nginx 使用独立配置与 PID，不覆盖系统 Nginx 或 ArgoX 配置。
- 迁移失败尝试恢复备份和原有服务；备份目录权限仅 root 可访问。
- `--upgrade` 升级脚本/服务管理，不重新下载或强制替换现有内核。

## 服务、自启和自愈

| 服务 | 作用 |
|---|---|
| `xray2go-core` | Xray |
| `xray2go-tunnel` | cloudflared |
| `xray2go-sub` | 独立 Nginx 订阅服务 |
| `xray2go-sync` | 自动同步隧道域名和四节点订阅 |

新安装默认开机自启。systemd 使用原生重启策略；Alpine/OpenRC 使用 `supervise-daemon`，异常退出或被 OOM 杀死后重启。Xray/Nginx/同步器重启延迟 5 秒，隧道 60 秒，避免反复申请临时域名触发 429。

**主动 stop 不会被同步器自动拉起。** 关闭订阅也会取消订阅服务自启。同步器只维护订阅，不循环检测并重启其他进程。Nginx 使用低负载单进程前台模式，避免主进程被杀后留下 worker 占端口。

Xray 设置 `GOMEMLIMIT=48MiB`、`GOGC=30`；cloudflared 设置 `GOMEMLIMIT=30MiB`、`GOGC=25`。这些是 Go 运行时软目标，不是硬上限，不保证永不 OOM。若内存不足持续 OOM，应减少负载或增加内存。

## 管理

`2go` 使用本机保存的当前版本，不会再运行 eooce 的原始脚本。

```bash
2go --version
2go --check
2go --restart       # 临时隧道重新申请，有 60 秒冷却
2go --upgrade       # 使用当前本机版本重建服务；获取更新应先下载新版
2go --uninstall
```

菜单支持：独立节点命名、RAW/XHTTP 端口、订阅端口、订阅开关、服务启停、固定/临时隧道、UUID、SNI、Argo 优选 IP/域名和端口、IPv4/IPv6 直连地址、Argo 内部端口。

固定隧道凭据通过服务器上的文件导入，不将 Token 粘贴到命令行。固定模式不会被旧临时隧道日志覆写。订阅只开放精确路径下的编码文本，不提供配置目录浏览。

## 卸载

卸载只停止和移除本脚本的专属服务，确认进程退出后再归档配置。不会卸载共享 Nginx 软件包，不调用全局 `pkill nginx`，不影响 ArgoX。配置、密钥和备份移到 root 目录，便于恢复；不直接销毁用户凭据。

若已从本脚本切换到其他脚本，不要执行不明归属的旧卸载程序。

## 测试

Linux 环境需 Bash、Python 3、jq、Nginx：

```bash
bash -n xray_2go.sh
python3 -m unittest discover -s tests -v
# root + util-linux；独立挂载命名空间验证卸载，不触碰宿主 /etc
unshare -m -- bash tests/uninstall_namespace.sh
```

回归包含命名/UUID/Vision/IPv6、端口定位、固定域名、原子订阅、真实 Nginx 文件隔离、凭据回滚与迁移失败恢复。OpenRC 的 SIGKILL 自愈和主动停止另在临时端口验收。

## 说明

继承上游四协议目标，保留来源与 MIT 授权。Hy2/TUIC 端口跳跃、AnyTLS、WARP、第三方订阅转换服务不属于本项目，不默认移入。安装不清空系统防火墙；如系统默认拒绝入站，需按自身防火墙策略放行选定端口。
