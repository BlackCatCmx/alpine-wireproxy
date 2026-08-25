# Alpine WireProxy WARP

这是一个面向 64MiB Alpine NAT 小鸡的最小化安装脚本：只运行 WireProxy 用户态 WireGuard 客户端，并提供 SOCKS5 WARP 出站，不修改主机全局路由、防火墙或 DNS。

脚本只支持 Alpine Linux + OpenRC + amd64。安装时会：

- 通过 Cloudflare 官方 WARP 注册接口生成临时设备账户；
- 下载固定版本的 WireProxy amd64 发布包；
- 创建 OpenRC 服务；
- 将 SOCKS5 监听在 `0.0.0.0`，并强制要求用户名和密码。

安装依赖仅为 `curl`、`openssl` 和 CA 证书；Alpine 自带的 BusyBox 提供其余工具。不安装 `wireguard-tools`、`wgcf`、`bash`、iptables、dnsmasq 或全局 WARP 客户端。

## 安装

```sh
sh wireproxy-warp.sh install \
  --stack dual \
  --port 41360 \
  --username proxyuser \
  --password 'change-this-password'
```

`--stack 4` 或 `--ipv4-only` 只经 WARP 访问 IPv4；`--stack dual` 或 `--dual-stack` 同时经 WARP 访问 IPv4 和 IPv6。默认端口是 `41360`，默认监听地址始终是 `0.0.0.0`，所以 `--username` 和 `--password` 不能省略。

密码不能包含空白字符、`#` 或 `=`，这是为了避免破坏 WireProxy 配置语法。

## 管理与测试

```sh
sh wireproxy-warp.sh status
rc-service wireproxy-warp restart
rc-service wireproxy-warp stop
```

在目标 Alpine 主机本机验证 SOCKS5：

```sh
curl --fail --socks5-hostname 127.0.0.1:41360 \
  --proxy-user 'proxyuser:change-this-password' \
  https://www.cloudflare.com/cdn-cgi/trace
```

## 卸载

```sh
sh wireproxy-warp.sh uninstall
```

卸载只删除本脚本创建的 OpenRC 服务、WireProxy 可执行文件和 `/etc/wireproxy-warp`；它不会改动主机全局网络配置。
