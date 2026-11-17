# Xray-2go 一键四协议

基于 [eooce/xray-2go](https://github.com/eooce/xray-2go)，直连协议为 VLESS-RAW-Reality-Vision 和 VLESS-XHTTP-Reality，另有 VLESS-WS-Argo、VMess-WS-Argo。补上原脚本里会失效的修改和卸载清理。

## 安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh)
```

NAT 机器可指定端口。`PORT` 后面连续两个端口会用于两个 Reality 节点：

```bash
PORT=开放端口 bash <(curl -Ls https://raw.githubusercontent.com/shadowxhero/xray-2go/main/xray_2go.sh)
```

## 本次修复

- 修改 RAW、XHTTP 端口时按协议定位配置，不再使用写死的配置行号。
- 只替换对应协议的节点链接，避免把另一个 Reality 节点的端口一起改掉。
- 临时 Argo 域名变化后，自动写回 VLESS 和 VMess 订阅，VMess 节点名保持 `-Argo` 后缀。
- 卸载时先停止 `argo-watch`，再删除文件并结束仍在运行的同步进程，避免旧进程继续操作已删除的脚本。
