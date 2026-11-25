# Xray-2go v2.1.5

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
PORT=43013 RAW_PORT=43011 XHTTP_PORT=43012 \
  bash <(curl -fsSL https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh) --install
```

`PORT` 是订阅端口；未设置 `RAW_PORT`、`XHTTP_PORT` 时分别使用 `PORT+1`、`PORT+2`。`ARGO_PORT` 默认 8080，仅供本机 cloudflared 回源。支持 `CFIP`、`CFPORT`、`UUID`、`SERVER_IP`、`NODE_NAME` 和 `PROTOCOLS`。

**`PROTOCOLS` 可以只装一部分协议**，例如只要两个直连 Reality、不装 Argo（省掉 cloudflared 的约 28MB 常驻内存）：

```bash
PROTOCOLS=raw-reality,xhttp-reality bash <(curl -fsSL .../xray_2go.sh) --install
```

可选值：`raw-reality`、`xhttp-reality`、`vless-argo`、`vmess-argo`。交互式安装会在选择「新安装」后再问一次，直接回车等于四个全装。

**NAT 服务器必须在服务商面板配置端口映射。** 订阅和两个直连节点使用 TCP。修改机器内的监听端口并不会自动创建公网映射；Argo 内部端口不需要映射。

## 原安装升级 / Caddy 迁移

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh) --upgrade
```

- 先备份，再检查 Xray、Nginx 配置，最后交接端口。
- 保留订阅端口、路径、UUID、REALITY 私钥/短 ID/SNI、Argo 优选地址及固定 JSON/Token 隧道。
- 旧 gRPC REALITY 节点转换为 RAW + Vision，原端口不变，客户端须更新订阅。
- 四节点分别命名为 `基础名-RAW-Reality`、`基础名-XHTTP-Reality`、`基础名-VLESS-Argo`、`基础名-VMess-Argo`。默认基础名沿用 Sing-box 的“国家代码-服务商”（例如 `US-ExampleISP`，空格转下划线），查询失败才退回 hostname。`NODE_NAME` 自定义优先。升级保留自定义名，旧版误用当前 hostname 的默认名会重新查询。
- 已不存在的旧 Caddy 服务不会因为残留配置文件阻断重复升级；升级失败会显示阶段，并回滚原配置与服务。
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
| `xray2go-sync` | 同步隧道域名、四节点订阅，并探测临时隧道是否存活 |

新安装默认开机自启。systemd 使用原生重启策略；Alpine/OpenRC 使用 `supervise-daemon`，异常退出或被 OOM 杀死后重启。Xray/Nginx/同步器重启延迟 5 秒，隧道 60 秒，避免反复申请临时域名触发 429。

**OOM 不再优先杀关键进程（v2.1.3）。** 内核的 OOM killer 按 `oom_badness` 选目标，占用最大的 xray/cloudflared 总是先被选中；cloudflared 一重启就重新申请临时隧道、换域名，客户端订阅随即失效。现在 `xray2go-core` 与 `xray2go-tunnel` 的 `oom_score_adj` 为 **-500**，`xray2go-sync` 为 **500**，`xray2go-sub` 保持 **0**：内存告急时优先牺牲同步器（5 秒拉起、无副作用），避免换域名。OpenRC 用 `start_pre` 写入 `/proc/self/oom_score_adj`（函数始终 `return 0`，不可写时不影响启动），systemd 用 `OOMScoreAdjust=`。

**临时隧道被 Cloudflare 回收时进程不会退出**：cloudflared 收到 `Unauthorized: Tunnel not found` 后一直重连，`supervise-daemon` 不触发重启，`argo.log` 里也不会再出现新域名，订阅就会长期指向一个 DNS 已消失的域名。v2.1.0 起同步器每 6 轮（约 60 秒）调用一次 `2go --health` 做存活探测：

- 判据是 `argo.log`：本次进程出现过 `Tunnel not found` 判死，没出现 `Registered tunnel connection` 也判死；
- 判据不发任何网络请求、不新增常驻内存。128MB 内存的机器上，每轮 fork 一个 `curl` 的瞬时峰值就足以把 cgroup 顶到上限触发 OOM kill；
- 隧道重启后 180 秒内不判定，等 cloudflared 重新拿到域名；
- 连续 3 次探测失败才重启 `xray2go-tunnel` 重新申请域名，重启同时写入 `last-renew`，与手动 `--restart` 共用 60 秒冷却；
- 只看日志的代价是：cloudflared 静默挂起（既不报错也不退出）时判不出来，需要手动 `2go --restart`。

**主动停止的隧道不会被拉起。** 关闭订阅也会取消订阅服务自启；`xray2go-tunnel` 被人为 stop 时健康探测会直接跳过，只有"服务在运行但域名已经不通"才会重启。Nginx 使用低负载单进程前台模式，避免主进程被杀后留下 worker 占端口。

这台机器的同步器仍然只做上面这些事，不会重启 Xray 或 Nginx。

Xray 设置 `GOMEMLIMIT=32MiB`、`GOGC=20`；cloudflared 设置 `GOMEMLIMIT=20MiB`、`GOGC=15`（v2.1.2 起，此前为 48/30 与 30/25）。这两个默认值可在安装或升级时用 `XRAY_GOMEMLIMIT`/`XRAY_GOGC`/`ARGO_GOMEMLIMIT`/`ARGO_GOGC` 覆盖（`XRAY_*` 在写服务定义时求值，改完需 `2go --repair`）。

这些都是 Go 运行时的软目标，不是硬上限，不保证永不 OOM。**128MiB 内存的机器即使调到上面这组值仍然很紧**：实测 `argo 30~39MB + xray 25~35MB + 第三方 agent 10~15MB`，cgroup 记账再加 page cache 就能顶到 128MiB 上限并触发 OOM kill（被杀一次就重申请临时隧道、换域名，客户端随即失效）。这种机器应当停掉非必要的常驻程序、把内存加到 256MiB 以上，或只保留 Reality 直连（去掉 cloudflared 可省约 36MB）。

暂时不能加内存时，可以在**机器本地**把 cgroup v2 的 `memory.high` 设为硬上限的 87.5%（128MiB → 112MiB），让内核提前回收页缓存而不是硬撞 `memory.max`：实测同一台机的 `memory.current` 从 116MB 降到 100MB、`workingset_refault` 增量为 0（没有性能抖动）。**这是机器级配置，不属于本脚本**——脚本管进程与协议配置，内存策略属于平台层；写死数值在扩容后会变成性能枷锁，所以按比例计算更稳。Alpine 下的做法是 `/etc/local.d/memory-tune.start` + `rc-update add local default`。

## 管理

`2go` 使用本机保存的当前版本，不会再运行 eooce 的原始脚本。

```bash
2go --version
2go --check
2go --restart       # 临时隧道重新申请，有 60 秒冷却
2go --health        # 读 argo.log 判定临时隧道存活，连续失败时重启隧道换域名
2go --protocols       # 查看/切换协议，见「协议增删」
2go --update        # 下载/校验并保存 GitHub 最新脚本，不重启服务
2go --repair        # 只用本机版本修复服务，保留配置，可能重启原服务
2go --upgrade       # 兼容旧命令，等同 --repair
2go --uninstall
```

新版已安装时，菜单 **2 是在线更新脚本**，菜单 **17 是修复当前服务**。旧版安装仍在菜单 2 提供保留配置迁移。

在线更新先下载到临时文件，再做 Bash 语法、版本和脚本结构检查；校验时不执行下载内容，不允许降级。旧脚本备份在本项目受限备份目录，校验失败不替换；相同内容不重复更新。更新不碰节点认证、订阅端口/路径、服务定义或内核，退出旧菜单后重新运行 `2go` 使用新版本。校验不等于独立签名认证，下载来源信任依赖 GitHub 官方仓库的 HTTPS。

**v2.0.8 起，已安装本项目的机器直接运行仓库一键命令（不加参数），就会先校验并同步本机脚本，再进入当前新版菜单，无需另选在线更新或添加 `--upgrade`。** 相同内容不重复写入，远端/外部旧版本不得覆盖本机新版；未安装机器只显示安装菜单，不自动安装。本机直接运行 `2go` 不强制联网。

旧版 `2go` 没有 `--update` 时，直接运行仓库一键命令即可获得该行为。旧 Caddy 安装尚未迁移的仍需显式选择迁移，不能把“保存新版脚本”当成“重建服务”。参数 `--upgrade`/`--repair` 只用于后者。

菜单支持：独立节点命名、RAW/XHTTP 端口、订阅端口、订阅开关、服务启停、固定/临时隧道、UUID、SNI、Argo 优选 IP/域名和端口、IPv4/IPv6 直连地址、Argo 内部端口。

### 临时隧道自愈与内存参数（v2.1.0 / v2.1.1 / v2.1.2）

上游只处理了“进程退出后重启”，没有处理“进程还活着、隧道已被云端回收”。v2.1.0 在同步循环里加入 `--health`，按“重启后 180 秒缓冲 + 连续 3 次探测失败”重启隧道重新申请域名，订阅随之刷新。

**v2.1.1 把探测判据从 HTTP 请求改成读 `argo.log`。** 128MB 内存的机器上（`memory.max` 128MiB），`--health` 每轮 fork 一个 `curl` 的瞬时峰值就会把 cgroup 顶到上限触发 OOM kill：实测 `memory.events` 的 `oom_kill` 累计 5 次、`memory.peak` 132.7MB 已超过上限，表现为 xray 与 cloudflared 被反复杀掉、客户端整机连不上。日志判据不联网，探测频率也降为约 60 秒一次。

**v2.1.2 把两个 Go 程序的内存软目标调低**（Xray 48MiB/GOGC30 → 32MiB/GOGC20，cloudflared 30MiB/GOGC25 → 20MiB/GOGC15），并支持用环境变量覆盖。同一台 128MiB 机器在 v2.1.1 之后 13 小时里仍被 OOM 杀了 2 次（`oom_kill` 5→7，`argo` 被杀后重申请临时隧道、域名改变、客户端全部失效），所以调低软目标属于缓解而不是根治。

**v2.1.3 用 `oom_score_adj` 把 OOM 的刀口挪到同步器上**。实测那台机的 `memory.current` 里 `anon` 只有 29MB，其余 77MB 是 xray(35MB)+cloudflared(40MB) 二进制的页缓存；OOM 并不挑“吃内存最多的坏进程”，而是按占用排序挑，于是两条关键链路总是先死。调整优先级后内存告急时先杀同步器（5 秒内被 `supervise-daemon` 拉起，不改任何状态），隧道域名不再变化，客户端的订阅也就不再作废。

**容器里这条保护只生效一半**：把 `oom_score_adj` 调成负值需要 `CAP_SYS_RESOURCE`，普通 LXC 容器没有该能力，写入会被拒绝（`Permission denied`，被 `start_pre` 的 `return 0` 吞掉，不影响服务启动）。所以容器内实际生效的只有同步器的 `+500`（`oom_score` 拉满到 1000，排序上始终先于 `xray`/`cloudflared`）；真正降低 OOM 概率还要靠 cgroup 的 `memory.high` 提前回收页缓存。

**升级后需要重建服务**（`2go --repair` 或菜单 17）才会写入新的 `sync-loop.sh`；只执行 `--update` 仅保存脚本，已经运行的同步循环内容不会改变。

### 恢复的交互方式（v2.0.6）

- 节点页恢复绿色标题、紫色链接、空行和分隔；新安装完成后直接展示。若已安装 `qrencode` 或保留旧二维码工具，则显示二维码，不强制下载第三方二进制。
- 修改 RAW、XHTTP、订阅、Argo 内部端口支持回车随机生成，最多尝试 100 次，跳过占用、当前配置以及 3001–3003 保留端口。随机范围为 2000–65000。NAT 用户应优先手动填写服务商允许的端口。
- 服务启停、隧道模式、订阅管理改为中文数字菜单；非法输入不再被当作关闭订阅。关闭/开启保留原订阅路径。
- SNI 提供候选列表和自定义输入，分别作用于 RAW 或 XHTTP；候选列表不代表相应站点的 TLS/后量子能力已经验证。
- 直连 IP 可自动获取 IPv4/IPv6 或手动填写；自动检测到 WARP 或无法确认出口时不更新。
- Argo 优选支持编号、回车保持当前、域名、IPv4、`域名:端口`、`[IPv6]:端口`；同时更新两个 Argo 节点，不改直连节点。

### 合并后的 Argo 优选预设

来源：[eooce/Sing-box](https://github.com/eooce/Sing-box)、[fscarmen/ArgoX](https://github.com/fscarmen/ArgoX)。2026-11-18 在两个网络环境中，通过实际 Argo 隧道的 SNI/Host 完成 TLS 握手与 WebSocket 转发验证，下列 8 个地址均返回 HTTP 101：

```
cf.090227.xyz
cf.877774.xyz
cf.877771.xyz
cdns.doon.eu.org
time.is
skk.moe
ip.sb
xn--b6gac.eu.org
```

排除：`cf.zhetengsha.eu.org`（无 A/AAAA）、`cfip.xxxxxxxx.tk`（NXDOMAIN）、`cdn.2020111.xyz`（SERVFAIL）、`bestcf.top`（转到域名到期地址，非正常入口）。这是当时的转发可用性结果，不是带宽排名，也不保证未来或所有运营商可用；不自动更换现有地址。

固定隧道凭据通过服务器上的文件导入，不将 Token 粘贴到命令行。固定模式不会被旧临时隧道日志覆写。订阅只开放精确路径下的编码文本，不提供配置目录浏览。

## 协议增删（v2.1.5）

四个节点可以独立启停，不用重装。菜单 **4. 协议管理** 列出四项当前状态，选编号即切换；命令行等价写法：

```bash
2go --protocols                        # 查看四个协议的开关状态
2go --protocols raw-reality,vless-argo # 只保留这两个
```

行为约定：

- 切换会重建 Xray 配置、校验通过后重启 core，失败自动回滚到原配置和原协议列表；
- **两个 Argo 协议都关闭时**，`argo-entry`/`fallback` 入站会被移除，`xray2go-tunnel` 随之停止并取消开机自启；重新打开任一 Argo 协议会再启用并重启它；
- 直连协议删除后端口记在 `state.json` 的 `ports` 字段，加回来优先复用同一个端口；该端口被占用时才重新分配；
- 最后一条协议不允许关闭（订阅会变成空的）；
- 新增 Reality 协议时，若配置里已经没有可复用的私钥，会现场生成一对新的 x25519 密钥。

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

**不依赖 coreutils，纯 busybox 的 Alpine 也能装。** v2.1.3 及以前在 `validate_xray_config` 里用 `mktemp "$work_dir/.validate.XXXXXX.json"`，而 busybox 的 `mktemp` 没有 GNU 的 `--suffix`，模板必须以 `XXXXXX` 结尾，于是全新安装到校验配置这一步直接报 `mktemp: : Invalid argument` 并触发失败归档。装了 coreutils 的机器（`mktemp` 走 GNU）不会复现，所以此前没有暴露。v2.1.4 起模板只写 `XXXXXX`、后缀自己拼，并在测试里用严格版 `mktemp` 兜住这个回归。`shuf`、`sort -V` 已确认 busybox 自带，无需额外依赖。

继承上游四协议目标，保留来源与 MIT 授权。Hy2/TUIC 端口跳跃、AnyTLS、WARP、第三方订阅转换服务不属于本项目，不默认移入。安装不清空系统防火墙；如系统默认拒绝入站，需按自身防火墙策略放行选定端口。
