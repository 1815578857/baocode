# 来源渠道

推广时想知道：从某个渠道来的用户，装了多少、留下了多少。BaoCode 的做法是：**进过官网的用户都算有来源**，来源记在用户自己的浏览器里；官网给他们**渠道版**，渠道版首次启动必须打开一次官网，把浏览器里记下的来源和安装 ID 一起报给统计服务。

不往安装包里写渠道（文件名、签名块、dmg 都试过，macOS 上带不进去），也不按 IP 匹配。

## 1. 浏览器：第一次进官网时记下来源（`site/site.js`）

官网任何一页都会跑这段，**只认第一次**：已经记过就不再改。来源按顺序取：

1. **渠道**：地址里 `?` 后面带的，任何一页都行：
   - `?ch=abc`
   - `?utm_source=abc`
   - 否则第一个参数：`?abc` 取 `abc`，`?from=abc` 取 `abc`。广告平台加的点击 ID（`gclid`、`fbclid`、`msclkid` 等）和其他 `utm_*` 跳过。
   - 取到的值去掉首尾空白、转小写，必须是 1–128 个字母（任何文字，所以 `?小红书` 也行）、数字、`.`、`_`、`-`，否则当没有。
2. **外站**：`document.referrer` 的域名，去掉 `www.`；baocode.dev 自己和它的子域名不算。
3. **直接访问**：都没有。

记成 `{"source":"channel"|"referrer"|"direct","value":"abc"|null,"at":"<ISO 时间>"}`，**IndexedDB**（库 `baocode`，表 `kv`，键 `attribution`）和 **localStorage**（`baocode.attribution`）各一份。读的时候取时间更早的那份；每次进站两处都重写一遍，一处被清了另一处能补回来。第一次记下时调用 `navigator.storage.persist()`，降低被浏览器清理的概率（Firefox 会为此弹授权框，所以 Firefox 上不调）。

已知会丢的情况：用户清了浏览器数据；Safari 的 ITP 在用户 7 天没访问网站后会清掉脚本写的所有存储；无痕窗口。

`/import`（地址里是用户的密钥）和 `/activate` 只读不写。

## 2. 渠道表：`site/channels.json`

任何 `?xxx` 都会被记下、计入统计，不用登记。**登记过的**渠道会在官网的三个地方显示：

1. **左上角**：BaoCode 的图标和名字换成渠道的 logo（`logo`，没有就不显示）和渠道名（`name`）。
2. **首页大标题**：`<渠道 logo> <渠道名> × <BaoCode logo> BaoCode`，渠道在前（`logo`、`name`）。
3. **首页副标题**：整句换成渠道的（`subtitle`）。

```json
{
  "youtube": {
    "logo": "/channels/youtube.svg",
    "name": { "zh": "YouTube", "en": "YouTube" },
    "subtitle": { "zh": "从 YouTube 来的朋友，欢迎！……", "en": "Welcome, friends from YouTube! …" }
  }
}
```

- 键是渠道 ID，**小写**（地址里的 `?YouTube` 会被转成 `youtube`）。
- 文字字段都是中英文各一份，按页面语言取；每个字段都可以不写，不写的地方保持原样。
- `logo` 放在 `site/channels/` 下（CSP 只允许站内图片），高度跟大标题的字一样，SVG 最好。用渠道的 logo 要先征得对方同意。
- 文字只当纯文本显示。显示的是浏览器里记下的**第一次**来源，所以同一个用户以后再来看到的都一样。
- 改完推到 `main` 就上线；这个文件缓存 5 分钟。
- **不闪**：每页 `<head>` 里的 `site/head.js` 在页面显示前判断（localStorage 里记的是渠道，或者还没记录但地址带 `?`），是的话先把这三处藏起来（位置保留，页面不跳），同时开始拉 `channels.json`；site.js 填好或确认不是登记过的渠道后再显示，最多藏 2 秒。新页面记得在 `<head>` 里加上它（更新日志页由 `tool/build_changelog.dart` 生成，已经带上）。

## 3. 下载：进过官网的给渠道版

页面里的下载链接仍然是 `/dl/<平台>`，拿到的是**非渠道版**（外站直接链过来、包管理器、脚本没跑）。site.js 读到清单后，**浏览器里有来源记录**时，把链接换成清单里该平台的 `channel.url`：

```json
"downloads": {
  "windows": { "url": "…/BaoCode-1.5.0-setup.exe", "size": 123, "channel": { "url": "…/BaoCode-1.5.0-setup-channel.exe", "size": 123 } }
}
```

清单里还没有 `channel` 时一切照旧。渠道版和非渠道版只差一个编译开关；自动更新一律给非渠道版，"待完成设置"的状态存在 app 的全局存储里，更新后还在。

## 4. 渠道版首次启动：必须完成设置

1. 首次启动在全局存储里记"待完成设置"，弹出不能关的欢迎窗（Escape、Enter 都不关），排在其他首启引导前面，整个 app 只弹一个。
2. 按钮打开 `https://baocode.dev/activate#i=<安装 ID>`（中文界面开 `/zh/activate`；英文页在中文浏览器里也会自己跳过去）。
3. 页面（`site/activate.js`）从 IndexedDB / localStorage 读来源：
   - 有：发 `POST https://stats.baocode.dev/v1/attribution`，`{"v":1,"id":…,"source":…,"value":…}`。
   - 没有（换了浏览器、微信里下载的）：给出这一页的链接让用户拿到原来的浏览器打开，或者"直接继续"，按 `source: "none"` 发。
4. 弹窗每 3 秒查一次 `GET https://stats.baocode.dev/v1/attribution/<安装 ID>`：200 就完成，404 就继续等。
5. **不依赖统计服务的备用路径**：页面发完（成功或失败）都会给出
   `baocode://activate?i=<安装 ID>&s=<source>&c=<value>`（`direct`、`none` 没有 `c`），
   一个按钮直接打开它，下面还能复制。macOS、Windows 已注册 `baocode://`；Linux 上把这个链接粘贴进弹窗里的输入框。app 校验 `i` 是自己的 ID、`s` 和 `c` 合规后就算完成，并在之后的 ping 里带上 `"attribution":{"source":…,"value":…}` 补报（服务端只认第一次，网页报过的不会被覆盖）。
6. 完成后清掉"待完成设置"，以后不再弹。弹窗里留一个"遇到问题"的入口（反馈或诊断上传）。

## 5. 统计服务（stats.baocode.dev，`baocode.dev` 仓库）

- `POST /v1/attribution`：只接受 `Origin: https://baocode.dev`，唯一开了 CORS 的接口；每个安装只记第一次。
- `GET /v1/attribution/<id>`：app 轮询用。
- `/v1/ping` 的可选字段 `attribution`：备用路径补报用。
- 表 `attributions(id, source, value, via, day)`；`GET /v1/stats/channels` 和仪表盘的"来源渠道"表：按来源看新增安装和 D1/D7/D30。

字段规则和响应见那个仓库的 README。

## 6. 隐私

记的只有来源（渠道 ID、来源网站的域名，或者"直接访问"），和安装 ID 一起，每个安装一次。不记访问过的页面，也不记来源网站的完整网址。官网上的隐私说明要写上"渠道版首次启动会打开一次官网"。
