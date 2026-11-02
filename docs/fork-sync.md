# 个人分支与官方更新对齐

## 长期分支

桌面端维护两条分支，不把定制修改混入官方主线：

- `main`：只同步 `upstream/main`，保持纯官方代码。
- `mobile-link`：官方基线加个人额度接口等修改，与自建手机端配套使用。

`origin` 指向个人 fork，`upstream` 指向 `https://github.com/baocode-dev/baocode.git`。本地 main 继续追踪 origin/main，mobile-link 追踪 origin/mobile-link；拉取官方更新时显式使用 upstream。本地分支整理不代表远程分支已经推送。

手机端位于同级 `../mobile`，是自建客户端，不是官方手机源码的 fork。手机端长期只维护 main，跟进桌面官方公开协议并保留自己的 UI 和扩展；不要把桌面仓库当作可合并的手机 Git 上游。

## 本次来源与配套版本

- 已验证的定制桌面基线：`a67bf443ee44224cfc846e68c6cb4ff019046b91`（1.8.0+24）。
- 个人额度接口来源：`3389b351`，迁移为新协议上的 quota RPC；整合时保留该原始提交的祖先关系，不强推重写历史。
- 手机端 main：`7219baf`，包含原有 5 条 UI/交互改动及协议迁移，已经推送个人仓库。
- 本次整理时官方 main 已到 `a2a19245`，比已验证基线多 7 条提交，包含新增“纯直连、不使用中继”契约。main 可跟进该官方提交；mobile-link 暂不引入这 7 条，避免手机尚未识别 direct 标志时仍添加默认中继。

临时集成分支和备份分支只有在内容已被保留分支完整包含、且没有其他 worktree 使用时才可删除。远程分支删除另行确认。

## 更新流程（手动，不自动写入）

1. 两个仓库分别检查 `git status --short --branch`，保留已有修改。
2. 桌面执行 `git fetch upstream`，检查本地 main 与 upstream/main 的差距，使用快进方式更新纯官方 main；main 不提交个人代码或同步说明。
3. 在 mobile-link 或它的临时开发分支整合已选择的官方更新，保留个人额度实现及测试。不使用强制同步或 reset 覆盖个人分支。
4. 手机依据 `docs/upstream-baseline.json` 的 link_transport 来源更新协议及 Rust 绑定；bao_editor 和呈现文件按各自旧来源逐项对比，不能整体覆盖 vendor 或 UI。
5. 两端一起验证连接、聊天及额度功能。官方新增连接行为（例如 direct-only）必须连同手机适配一起验证，不能只更新桌面就宣称兼容。
6. 桌面定制修改提交到 mobile-link，手机修改提交到手机 main；桌面 main 始终保持纯官方。推送和删除远程分支仍需当次授权。

## 协议与验证边界

当前配套版本是官方 link v2：iroh/QUIC、Ed25519、ALPN baocode/link/2。旧 WebSocket/X25519 配对保留为需要重新配对的记录，不静默复用旧密钥，也不重放可能已执行的写请求。

已验证桌面连接相关测试 53 项、手机相关测试 109 项、Android 发现协议纯 Java 6 项断言。连接测试仅使用内存网络和本机合成数据，不访问真实项目或共享中继。尚未验证完整 Android/Kotlin 构建、真机及真实跨网行为。
