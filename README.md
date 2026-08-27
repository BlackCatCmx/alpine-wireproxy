# Alpine WireProxy WARP

面向 64 MiB Alpine NAT VPS 的轻量 WARP SOCKS5 出站代理。只运行 WireProxy 用户态 WireGuard，不接管主机全局路由、防火墙或 DNS。默认使用 WireProxy 内部的 Cloudflare DNS `1.1.1.1`，也可以切换为容器或主机原生 DNS。

支持 Alpine Linux、OpenRC、amd64；默认监听 `0.0.0.0`，鉴权始终必填。

## 安装

Alpine 不会预装 `wireproxy-warp.sh`。下面的一行命令会下载脚本并立即执行：

```sh
wget -qO /root/wireproxy-warp-install.sh https://raw.githubusercontent.com/BlackCatCmx/alpine-wireproxy/main/wireproxy-warp.sh && sh /root/wireproxy-warp-install.sh install --stack dual --port 41360 --username proxyuser --password 'change-this-password'
```

安装器启动 WireProxy 后会立即返回，并在后台依次检测 Cloudflare 下发的 IPv4、IPv6 Endpoint。新 WARP 账户可能需要几分钟才能可用；检测成功后自动保留可用 Endpoint 并退出，连续数分钟仍失败也会记录结果并退出，不会留下常驻检测进程。

OpenRC 会在 WireProxy 进程异常退出时自动拉起进程。默认启用的轻量 watchdog 每 15 分钟通过本机 IP 形式 SOCKS5 检查一次 WARP 隧道；连续三次失败且主机直连网络正常时自动重启 WireProxy。主机出口或 Cloudflare 整体不可达时不会重启。watchdog 不检查 `socks5h`，因此单独的代理端 DNS 故障不会触发重启。

参数：

```text
--stack 4|dual       WARP 出站类型，默认 dual
--ipv4-only          等同于 --stack 4
--dual-stack         等同于 --stack dual
--port PORT          SOCKS5 端口，默认 41360
--username USER      必填用户名
--password PASSWORD  必填密码
--dns cloudflare|native
                     DNS 方案，默认 cloudflare（1.1.1.1）
```

密码不能包含空白字符、`#` 或 `=`。

## 管理

安装后使用管理入口：

```sh
warp          # 打开菜单
warp status
warp test
warp retry
warp restart
warp dns cloudflare
warp dns native
warp watchdog status
warp watchdog on
warp watchdog off
warp switch 4
warp switch dual
warp uninstall
```

`warp status` 只读取服务、当前 Endpoint 和后台检测状态，不发起网络请求，也不修改配置。`warp test` 通过本机 SOCKS5 做一次真实的 `warp=on` 检测，但不修改配置。`warp retry` 使用现有账户在后台重新检测 IPv4、IPv6 Endpoint，不重新下载、注册账户或生成密钥。

菜单还提供重启服务、切换 IPv4-only、切换双栈、切换 Cloudflare/原生 DNS 和卸载。切换会实际修改 WireProxy 配置并重启服务，不会重新注册 WARP 账户。

watchdog 开关无需重启服务即可生效。关闭后不再进行主动网络检测或因检测失败而重启，但 OpenRC 的进程崩溃自动拉起仍然有效。`warp status` 会显示开关状态和最近一次检测结果。

重启或切换不会改变安装时选出的可用 Endpoint。

## 代理测试

```sh
curl --fail --proxy socks5://127.0.0.1:41360 \
  --proxy-user 'proxyuser:change-this-password' \
  https://www.cloudflare.com/cdn-cgi/trace
```

`socks5` 由客户端解析域名，`socks5h` 由代理解析域名。IPv4-only 客户端如果本地 DNS 返回 AAAA，应强制使用 IPv4；双栈两种方式都支持。

检查代理端 DNS 时使用：

```sh
curl --fail --proxy socks5h://127.0.0.1:41360 \
  --proxy-user 'proxyuser:change-this-password' \
  https://cp.cloudflare.com/cdn-cgi/trace
```

## 卸载

```sh
warp uninstall
```

卸载只移除本项目创建的服务、管理入口、WireProxy 二进制和 `/etc/wireproxy-warp`。
