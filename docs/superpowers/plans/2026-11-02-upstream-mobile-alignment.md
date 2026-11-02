# 官方追踪与自建手机客户端兼容 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 桌面端以纯官方 main 和个人 mobile-link 分开维护，自建手机端只维护 main，保留既有改动并兼容官方新协议。

**Architecture:** 桌面 origin 保持个人 fork，upstream 指向 baocode-dev/baocode；在临时集成分支使用官方 a67bf443 基线。手机端不是官方源码 fork，继续使用自己的 origin，更新其 vendored bao_link 并引入同基线 bao_iroh，适配 iroh/Ed25519 配对、发现、存储及本地测试宿主。quota 是个人扩展，手机连接不支持该接口的官方桌面时降级提示而不影响基础功能。

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.4+，Rust，iroh，Android Kotlin。

**Spec:** 用户在本会话确认：手机不开源且为自建实现，可直接适配；手机只保留一个追踪官方协议且兼容个人分支的版本；桌面跟进官方并保留个人修改。无需维持旧协议双栈。

## 收尾授权更新

用户随后确认手机端提交并推送 main（已到 7219baf），桌面 main 只放官方代码，mobile-link 保留个人修改，并清理已整合的本地临时/备份分支。下方“不提交/不移动 main”的约束记录的是开发阶段；本次收尾按新授权执行本地提交、分支整合和安全删除，仍不擅自推送桌面或删除远程分支。

最新官方 main 为 a2a19245，新增 7 条提交涉及 direct-only。桌面 main 跟进官方；配套 mobile-link 仍保留已验证的 a67bf443 基线，新增连接契约留待手机同步适配，不在分支清理中扩展业务行为。

## Global Constraints

- 不自动 commit/push、删除分支、改写历史、发布或安装真实设备；不连接真实业务电脑或共享中继做测试。
- 所有开发在 integrate/upstream-mobile-20261102 临时分支，main 暂不移动；已有功能分支保留。
- 官方基线固定 a67bf443ee44224cfc846e68c6cb4ff019046b91，手机既有改动固定 d1003a1，桌面 quota 原始提交 3389b351。
- 手机端保留 UI/交互和 Android 发现生命周期拆分；不整体覆盖渲染/呈现目录。
- 旧身份保留记录并提示重新配对，不静默删除信任信息；不自动重放写请求。
- 仅运行相关测试、定向分析；验证不足必须明确报告。

## Review Focus

- 旧 X25519 存储不能作为 Ed25519 身份复用，也不能自动信任新设备。
- 配对取消、存储失败、并发重连和 dispose 不得残留连接或信任。
- 原始桌面无 quota 扩展时仅降级额度功能；不得吞掉其他真实错误。
- 协议/session 增量变化不得导致聊天丢消息、误重放发送或破坏子代理入口。
- iroh 原生资源与 Android/桌面编译环境可能缺失，不将内存测试冒充实机验证。

---

### Task 1: 桌面官方追踪与额度接口迁移

**Files:** lib/link/workspace_bridge.dart；packages/bao_link/lib/src/protocol.dart；test/link/workspace_bridge_test.dart。

**Interfaces:** 维持 LinkMethods.quota = 'quota'，参数 provider/session/refresh；返回 providers/accounts 公开额度快照，最多等待 20 秒。

- [x] 检查干净工作区、增加 upstream、拉取官方并创建集成分支。
- [x] 将原额度回归测试移到新版桥接基线，补充必要错误/超时断言。
- [x] 在新版实现 quota，不改变官方已有方法和配对契约。
- [x] 运行定向测试与分析，记录工具链阻塞。

### Task 2: 手机端新协议及生命周期适配

**Files:** vendor/bao_link；vendor/bao_iroh；pubspec.yaml/pubspec.lock；lib/link/phone_link.dart；lib/link/desktop_discovery.dart；必要的设备 UI 和本地 fixture；test/link 和 test/state 中相关测试。

**Interfaces:** 官方 LinkNode/LinkConnection/LinkPeer，PairingOffer/LinkAddress，协议 v2 和 Ed25519。保持 PhoneLink 面向上层的业务调用接口，测试注入 MemoryLinkNetwork，运行时 IrohLinkNode。

- [x] 从 origin/fix/mobile-layout-and-chat 创建集成分支，保留 5 条改动。
- [x] 更新官方共享协议包及 Rust 绑定，保留 quota 扩展，记录固定来源。
- [x] 先补充新协议配对、身份迁移、重连、取消和存储失败测试，再实现连接迁移。
- [x] 适配设备发现、地址/中继、重新配对提示、本地合成宿主；旧身份不得自动升级信任。
- [x] 定向验证相关链路和已有聊天功能测试；不使用真实会话。

### Task 3: 额度降级与可重复追踪

**Files:** 手机额度 UI/状态及测试；两端同步说明；手机 docs/upstream-baseline.json；必要的只读基线检查工具。

**Interfaces:** 无扩展桌面返回 unknown/unsupported 时显示不支持；其他异常保持可见。来源记录区分官方基线与个人扩展。

- [x] 编写并运行不支持额度接口的回归测试，再实现明确降级。
- [x] 记录官方基线、个人补丁及两端配套测试矩阵；不添加后台自动写入或定时任务。
- [x] 独立复查两个仓库 diff、定向分析/测试结果及未验证风险。
- [x] 保留临时分支和未提交状态，未移动 main、未 push；后续整合按用户授权执行。

## 验证结果

- 桌面相关连接测试：53 通过；定向分析无问题。
- 手机连接、状态、额度及原有界面/交互相关测试：109 通过，包含 1 项真实 iroh 本机直连测试。
- Android 发现协议纯 Java：javac --release 17 编译成功，6 项断言通过。
- 官方包快照：33 个文件核对，只有 quota 声明为个人差异。
- 手机定向分析无错误，保留 6 条风格 info；源结构检查无问题。
- 没有运行全套测试、Android/Kotlin 构建、真机或共享中继验收。
- 独立复查后修正重连被存储失败阻断、取消配对提前成功两个问题；故障用例先失败，再经修正后的 109 项相关测试验证。

