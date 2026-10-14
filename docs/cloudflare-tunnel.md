# 公网访问：Cloudflare Tunnel

手机在外网连桌面端，本来是靠「公网地址」直连（路由器转发端口，或桌面端自己的公网 IPv6）。没公网 IP、又不想开路由器端口时，可以用 Cloudflare Tunnel 把本机的 47100 暴露出去，地址固定成 `link.baocode.dev`。

这份文档记录**为什么这么做**、**用 Cloudflare MCP 怎么做**，以及**本机常驻服务怎么装**。协议和配对见 [`mobile-link.md`](./mobile-link.md)。

## 1. 为什么用 80 端口

关键约束：手机端的连接地址是写死 `ws://` 的（[`packages/bao_link/lib/src/io.dart`](../packages/bao_link/lib/src/io.dart) 的 `LinkConnector._race`），没有 `wss://` 分支。

而 Cloudflare 的隧道入口**强制 HTTPS**：`443` 端口上的明文 `ws://` 请求会被 CF 直接拦掉（`400 Bad Request`，`CF-RAY: -`，根本没进隧道）。它只在 **80 端口**上接受明文 `ws` 升级再回源。

所以走法只有一个：

```
手机 → ws://link.baocode.dev:80/baocode-link
     → Cloudflare（80，接受明文 ws 升级）
     → 隧道 → http://localhost:47100（本机 LinkServer）
```

`always_use_https` 必须为 **off**（`baocode.dev` 本来就是），否则 80 端口会 301 跳转到 HTTPS，明文 `ws` 升级就断了。`automatic_https_rewrites` 开着不影响 WebSocket 升级，可以不管。

实测三种走法：

| 走法 | 结果 |
| --- | --- |
| `wss://link.baocode.dev:443/baocode-link` | ✅ 101（但客户端不会用） |
| `ws://link.baocode.dev:80/baocode-link` | ✅ 101 ← **用这个** |
| `ws://<任何域名>:443/baocode-link` | ❌ CF 400 |

手机上填的「公网地址」：

```
link.baocode.dev:80
```

必须带 `:80`。不带端口会被当成默认端口 47100（[`lib/link/link_host.dart`](../lib/link/link_host.dart) 的 `_parse`），连到 CF 的 47100 上，不通。

## 2. 资源清单

| 资源 | 值 |
| --- | --- |
| 账号 | `d65fe67428884b9d2b06125e3afe605a` |
| 域名 | `baocode.dev`，zone `d1d792adc07895ac5b4d029107a6e1f5` |
| 隧道 | `baocode-link-local`，id `c9a2003c-7cd6-425a-8ae8-b7d531b82815` |
| 回源 | `http://localhost:47100` |
| DNS | `link` CNAME → `c9a2003c-….cfargotunnel.com`，proxied |

## 3. 用 MCP 配置（可复现全过程）

用 Cloudflare MCP：`search` 查 OpenAPI 端点，`execute` 写 JS 调 `cloudflare.request()`。JS 里能拿到 `accountId`。

**a. 先看现状**（哪些域名、隧道、DNS、zone 设置）：

```js
async () => ({
  accounts: (await cloudflare.request({ method: 'GET', path: '/accounts' })).result,
  zones: (await cloudflare.request({ method: 'GET', path: '/zones' })).result
    .map(z => ({ name: z.name, id: z.id })),
})
```

确认三个前提：`always_use_https` 是 `off`、目标子域没有占用、没有同名隧道。

```js
await cloudflare.request({
  method: 'GET',
  path: `/zones/${zoneId}/settings/always_use_https`,
})
```

**b. 建隧道**：

```js
const t = (await cloudflare.request({
  method: 'POST',
  path: `/accounts/${accountId}/cfd_tunnel`,
  body: { name: 'baocode-link-local', config: { ingress: [] } },
})).result
```

创建时传的 `config` 对**本地管理型**隧道（用 token 跑的）不生效，后面必须单独推 ingress，见 d。

**c. 拿 token**（这是秘密，别提交）：

```js
const tok = (await cloudflare.request({
  method: 'GET',
  path: `/accounts/${accountId}/cfd_tunnel/${tunnelId}/token`,
})).result
```

**d. 推 ingress**：

```js
await cloudflare.request({
  method: 'PUT',
  path: `/accounts/${accountId}/cfd_tunnel/${tunnelId}/configurations`,
  body: {
    config: {
      ingress: [
        { hostname: 'link.baocode.dev', service: 'http://localhost:47100' },
        { service: 'http_status:404' },   // 兜底，必须有
      ],
    },
  },
})
```

最后一条兜底规则是必需项，少了 API 会报错。

**e. 加 DNS**：

```js
await cloudflare.request({
  method: 'POST',
  path: `/zones/${zoneId}/dns_records`,
  body: {
    type: 'CNAME', name: 'link',
    content: `${tunnelId}.cfargotunnel.com`,
    proxied: true,
  },
})
```

**f. 本机跑起来**（见下一节，然后确认日志里出现 `Updated to new configuration`）：

```bash
cloudflared tunnel --no-autoupdate run --token-file ~/.cloudflared/link-tunnel.token
```

坑：隧道进程**只有在启动时会去拉一次远程 ingress**。先起进程、后推配置的话，得重启进程才会生效——日志里会一直重复 `No ingress rules were defined`，此时请求经 CF 回来是 503。

## 4. 常驻服务（launchd）

token 存在 `~/.cloudflared/link-tunnel.token`（权限 600）。LaunchAgent 放在 `~/Library/LaunchAgents/dev.baocode.cftunnel-link.plist`：

```xml
<key>ProgramArguments</key>
<array>
  <string>/opt/homebrew/bin/cloudflared</string>
  <string>tunnel</string>
  <string>--no-autoupdate</string>
  <string>run</string>
  <string>--token-file</string>
  <string>/Users/leokun/.cloudflared/link-tunnel.token</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
```

`SuccessfulExit=false`：正常退出不重启，异常挂掉才拉起。日志在 `~/Library/Logs/cftunnel-link.log`。

```bash
# 装 / 更新
launchctl bootout gui/$(id -u)/dev.baocode.cftunnel-link 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.baocode.cftunnel-link.plist

# 看状态
launchctl print gui/$(id -u)/dev.baocode.cftunnel-link | grep -E "state|pid"

# 停掉（保留配置）
launchctl bootout gui/$(id -u)/dev.baocode.cftunnel-link
```

不想用 launchd 的话，`brew services` 不行——它管的是 `~/.cloudflared/config.yml` 那套，和 token 方式对不上。

## 5. 排错

```bash
# 域名有没有回源到本地：两边都应返回 404 + body "BaoCode"
curl -s http://link.baocode.dev:80/
curl -s http://localhost:47100/

# WebSocket 升级（要看到 101）
curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     http://link.baocode.dev:80/baocode-link
```

| 现象 | 原因 |
| --- | --- |
| 503 + 日志 `No ingress rules` | 进程没拉到配置，重启它 |
| 502 | ingress 生效了但回源失败：本机 47100 没在监听 |
| `ws://…:443` 返回 400 | 正常，CF 在 443 上只收 TLS |
| 浏览器能开但手机连不上 | 手机连的是 `ws`，不是 `https`；别用浏览器结果判断 |

## 6. 注意

- **免费版 ToS 禁止用非 Web 端口代理服务**。这里是拿 80 端口跑 WebSocket 隧道，属于自己临时用的范畴；要正经给用户用，还是得实现 [`mobile-link.md`](./mobile-link.md) §5 预留的中转（`RelayEndpoint`）。
- 隧道是**这台机器**的：换机器要重新装 token 和 plist。
- 域名固定（`link.baocode.dev`），比 `trycloudflare.com` 的随机域名强——后者每次重启都变，二维码要重扫。
- 根路径返回 404 + `BaoCode` 是正常的：`LinkServer` 只处理 `/baocode-link` 的 WebSocket 升级。
