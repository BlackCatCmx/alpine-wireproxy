# Alpine WireProxy WARP

面向 64 MiB Alpine NAT VPS 的轻量 WARP SOCKS5 出站代理。只运行 WireProxy 用户态 WireGuard，不接管主机全局路由、防火墙或 DNS。

支持 Alpine Linux、OpenRC、amd64；默认监听 `0.0.0.0`，鉴权始终必填。

## 安装

Alpine 不会预装 `wireproxy-warp.sh`。下面的一行命令会下载脚本并立即执行：

```sh
wget -qO /root/wireproxy-warp-install.sh https://raw.githubusercontent.com/BlackCatCmx/alpine-wireproxy/main/wireproxy-warp.sh && sh /root/wireproxy-warp-install.sh install --stack dual --port 41360 --username proxyuser --password 'change-this-password'
```

`sh wireproxy-warp.sh` 的意思是“让 `sh` 执行当前目录中已经存在的文件”，不是 Alpine 自带命令。

参数：

```text
--stack 4|dual       WARP 出站类型，默认 dual
--ipv4-only          等同于 --stack 4
--dual-stack         等同于 --stack dual
--port PORT          SOCKS5 端口，默认 41360
--username USER      必填用户名
--password PASSWORD  必填密码
```

密码不能包含空白字符、`#` 或 `=`。

## 管理

安装后使用管理入口：

```sh
warp          # 打开菜单
warp status
warp restart
warp switch 4
warp switch dual
warp uninstall
```

菜单提供状态查看、重启服务、切换 IPv4-only、切换双栈和卸载。切换会实际修改 WireProxy 的 `Address` 与 `AllowedIPs`，不会重新注册 WARP 账户。

## 代理测试

```sh
curl --fail --proxy socks5://127.0.0.1:41360 \
  --proxy-user 'proxyuser:change-this-password' \
  https://www.cloudflare.com/cdn-cgi/trace
```

`socks5` 由客户端解析域名，`socks5h` 由代理解析域名。IPv4-only 客户端如果本地 DNS 返回 AAAA，应强制使用 IPv4；双栈两种方式都支持。

## 卸载

```sh
warp uninstall
```

卸载只移除本项目创建的服务、管理入口、WireProxy 二进制和 `/etc/wireproxy-warp`。
