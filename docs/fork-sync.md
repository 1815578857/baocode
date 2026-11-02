# 个人分支与官方更新对齐

## 长期分支

桌面端维护两条分支，不把定制修改混入官方主线：

- `main`：只同步 `upstream/main`，保持纯官方代码。
- `mobile-link`：官方基线加个人额度接口等修改，与自建手机端配套使用。

`origin` 指向个人 fork，`upstream` 指向 `https://github.com/baocode-dev/baocode.git`。本地 main 继续追踪 origin/main，mobile-link 追踪 origin/mobile-link；拉取官方更新时显式使用 upstream。本地分支整理不代表远程分支已经推送。

手机端位于同级 `../mobile`，是自建客户端，不是官方手机源码的 fork。手机端长期只维护 main，跟进桌面官方公开协议并保留自己的 UI 和扩展；不要把桌面仓库当作可合并的手机 Git 上游。

## 本次来源与配套版本

- 官方来源固定为 `6baa74567ddcb631c8766ac4c0ef9995a7c869df`，不随 `upstream/main` 新 HEAD 漂移（2026-11-02 核对时 `upstream/main` 已到 `408240b2`，本批有意不跟进）。
- 纯官方 `main` 只做快进同步；`a2a19245` 是 `6baa7456` 的祖先，何时快进由维护者另行决定。
- `mobile-link` 整合官方 `6baa7456`，并保留个人 quota 实现及其对外错误脱敏（`lib/link/workspace_bridge.dart`、`test/link/workspace_bridge_test.dart`）。
- 唯一的个人协议差异是 `quota`：`packages/bao_link/lib/src/protocol.dart` 相对 `6baa7456` 只多一条方法声明（7 行），`packages/bao_iroh` 与官方无差异；手机 `vendor/*` 的 33 个官方文件比对结果同样只差这条声明。
- 个人额度接口来源：`3389b351`，迁移为新协议上的 quota RPC；整合时保留该原始提交的祖先关系，不强推重写历史。
- 手机端 main 配套这套协议；手机是尽量复刻官方体验的自建 Android 客户端，不是官方手机源码的 fork；官方功能按契约实现，个人增强（如 quota）可选降级。

历史记录（非本批结果）：此前已验证的定制桌面基线是 `a67bf443ee44224cfc846e68c6cb4ff019046b91`（1.8.0+24）；当时官方 main 在 `a2a19245`，比该基线多 7 条提交，包含“纯直连、不使用中继”契约，并因手机尚未识别 direct 标志而暂不引入。现在手机已按 `6baa7456` 适配 direct 与 Bot notices，`mobile-link` 对 `6baa7456` 的整合引入了它们。

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

本批已验证（本机宿主，仅合成数据与内存网络，不访问真实项目或共享中继）：

- 桌面：`flutter test --no-pub test/link` 56 项通过，其中 `workspace_bridge_test.dart` 23 项通过；该文件与 `lib/link/workspace_bridge.dart` 定向 `dart analyze` 无问题。
- quota 对外边界：服务缓存里的非空上游错误文本不再原样发给手机，统一为固定中文提示“额度状态异常”；null 仍为 null；刷新失败/超时的固定文案仍优先；不修改 CodexService 内部诊断。合成测试覆盖“无 refresh”与“`refresh: true` 但服务不抛错”两种情况，只使用合成标记，不含真实凭据；已通过临时回退实现验证测试会变红。
- 手机配套（`../mobile`）：连接、状态、Bot、设备页相关 151 项通过；其中原生测试使用真实 iroh，只拨号环回、无共享中继，`Iroh.bind` 可能绑定本机网卡，不能表述为端点只绑定 loopback。细节见手机 `docs/upstream-sync.md`。

历史记录（非本批结果，本批未复跑）：桌面连接相关测试 53 项、手机相关测试 109 项、Android 发现协议纯 Java 6 项断言。

未验证：完整 Android/Kotlin 构建、APK、真机与扫码；与官方闭源手机应用的互通；真实跨网打洞与共享中继；系统通知在真机上的行为。

已知限制（不自动修复，详见手机文档）：策略切换重建端点时在线状态会短暂闪烁；另一台电脑改变策略可能打断等待审批的附近配对；`updateRelays` API 保留但设备页无入口；非 direct 且二维码 `r` 为空时首次拨号有内置中继窗口；Bot 通知 ID 依赖桌面系统时钟（时钟回拨加桌面重启可能回退），通知也不是可靠队列。手机从旧版升级后的首次重连：已信任但尚未公布策略的记录，有中继提示就按提示拨号，没有就回退内置中继列表，所以第一次重连可能仍按旧版保存的中继拨号，即使电脑已切到仅直连；收到 hello 并保存新策略后才停止。
