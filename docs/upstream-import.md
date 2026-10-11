# 上游一键导入与推荐上游

上游站点（多为 new-api / sub2api）在自己的令牌页放一个「导入到 BaoCode」的链接，
用户点一下，上游连同密钥就加进 BaoCode。作为回报，BaoCode 在 设置 → 模型 顶部
用小卡片免费展示接入了的站点。

```
站点令牌页「导入到 BaoCode」
  → https://baocode.dev/import#v=1&name=…&protocol=…&url=…&key=…   (site/import.js)
      参数在 # 后：浏览器不发给服务器；页面读完即从地址栏清除
  → baocode://provider/import?v=1&name=…&protocol=…&url=…&key=…
      macOS：Info.plist 注册，AppDelegate.swift → OpenRequests
      Windows：tool/baocode.iss 注册，--baocode-link → open_requests.cpp
  → Flutter：code_args.dart 的 importRequestMarker → workbench._importUpstream
      → upstream_import_dialog.dart 确认（可改名）→ ModelProviders 写入 + 钥匙串
      → 打开 设置 → 模型 中这个上游的页面
```

## 链接参数

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `v` | 否 | 版本，目前只有 `1`；其他值拒绝 |
| `url` | 是 | Base URL，http 或 https。new-api 用 `{address}` 即可：Anthropic 协议 Claude Code 自己加 `/v1`，OpenAI 协议缺版本时 BaoCode 补 `/v1`（`UpstreamUrls`） |
| `protocol` | 否 | `anthropic`（默认）、`openai-chat`、`openai-responses`。不接受 `codex`（它用账号登录，没有 key） |
| `name` | 否 | 显示名，最长 64；缺省用 host |
| `key` | 否 | API key，最长 512；缺省时导入后再填 |

只接受这几个字段，这是安全边界：上游的 `env`（会成为 Claude Code 的环境变量，
能用来执行代码）、认证方式、模型列表等都不能经链接写入。未知参数忽略。

同一协议、同一 Base URL 的上游已存在时，确认框给「更新它的密钥」和「另存为新上游」。

## 推荐上游（卡片）

收录表：`assets/upstreams/upstreams.json`，Logo 放在同目录。随应用发布，所以新收录
跟着下一个版本出现。

```json
{
  "version": 1,
  "upstreams": [
    {
      "id": "example",
      "name": "Example",
      "url": "https://example.com/register?aff=xxxx",
      "logo": "example.svg",
      "description": { "en": "Claude and GPT at cost price", "zh": "Claude、GPT 成本价直供" },
      "hosts": ["api.example.com", "example.com"]
    }
  ]
}
```

- `url`：点卡片打开的地址，允许带推广参数。
- `logo`：SVG 或 PNG（建议 64×64 以上、正方形、自带底色，深浅主题都能看清）；
  缺省显示名称首字母。
- `hosts`：从这些域名导入时，确认框写「已收录在 BaoCode：名称」。只是提示，
  未收录的站点导入不受任何限制。
- 卡片顺序每次打开页面随机；最后一张固定为「展示你的站点」，指向 /upstreams。

## 收录流程

1. 站长按 https://baocode.dev/upstreams 接入一键导入。
2. 站长用 issue 模板「收录我的上游」（`.github/ISSUE_TEMPLATE/upstream-listing.yml`）提交。
3. 维护者：
   - 注册一个账号，在令牌页实际点一次导入，确认能成功添加并列出模型；
   - 核对 `hosts` 确实是该站的 API 域名；
   - 通过 issue 里的联系方式要 Logo，处理成正方形放进 `assets/upstreams/`；
   - 往 `upstreams.json` 加一条，PR 引用 issue。
4. 下架：导入失效、域名易主、误导用户（例如冒充官方），删掉条目即可，在 issue 里说明。

## 给站长的接入提示词（草稿）

官网 /upstreams 页面上放的、让站长直接丢给 AI 的提示词：

> 在我的站点（new-api / sub2api / 自研）令牌列表的每个令牌旁加一个「导入到
> BaoCode」按钮，点击后在新标签页打开：
> `https://baocode.dev/import#v=1&name=<站点名>&protocol=<anthropic|openai-chat|openai-responses>&url=<API 地址，不带 /v1>&key=<该令牌的完整 key>`
> 每个参数值都要 encodeURIComponent。参数必须放在 `#` 后面，不能放在 `?` 后面，
> 这样 key 不会经过任何服务器。按钮使用 BaoCode 图标（附 SVG）和文字「导入到
> BaoCode」。不要引用 baocode.dev 的任何脚本。

new-api 不用改代码：系统设置 → 聊天设置 里加一行即可（`{address}`、`{key}` 由
new-api 替换）：

```json
{ "BaoCode": "https://baocode.dev/import#v=1&name=站点名&protocol=anthropic&url={address}&key={key}" }
```

待核实：不同 new-api 版本里 `{key}` 替换出来带不带 `sk-` 前缀不一致，审核时在真实
站点上点一次，确认导入后的 key 能用；不带时模板写成 `key=sk-{key}`。
