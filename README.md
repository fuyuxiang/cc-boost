# cc-boost

[![GitHub stars](https://img.shields.io/github/stars/fuyuxiang/cc-boost?style=social)](https://github.com/fuyuxiang/cc-boost/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-plugin-6b46c1)](.claude-plugin/plugin.json)
[![Runtime](https://img.shields.io/badge/runtime-bash%20%2B%20jq%20%2B%20curl-222)](scripts/)

> 面向 Claude Code 的弱模型编码加固插件：本地检查兜底、跨模型 verifier 门控、Best-of-N 选最优、失败账本记录，让 MiniMax、GLM、Kimi、DeepSeek、Qwen 等更便宜的编码模型在真实项目里更稳定。

## 安装

```text
claude
> /plugin marketplace add fuyuxiang/cc-boost
> /plugin install cc-boost@fuyuxiang
> /reload-plugins
```

在你的业务项目里初始化：

```text
> /cc-init
> /cc-doctor
```

`/cc-init` 会在当前项目生成一个被整体 gitignore 的 `.cc-boost/` 目录，里面包含 `agent-check.sh`、配置、质量 baseline、失败账本、review packet 和本地规则快照。之后正常使用 Claude Code 即可；cc-boost 会在后台跑检查、区分历史失败和新增回归，并在非平凡 diff 上调用 verifier。

无任何 verifier key 也能装。`/cc-init` 在没有 key 时仍会完成初始化、启用 Layer A 的所有能力（本地检查、失败账本、lessons 注入、`/cc-task` 的候选生成），Layer B 使用 `verifier.enabled: "auto"`，并用中文提示如何配置 OpenAI API 格式的 verifier。后续配上三个 `CC_BOOST_VERIFIER_*` 环境变量后，重启 Claude Code 会话并运行 `/cc-doctor` 检查状态。

## 快速上手

cc-boost 不参与 Claude Code 自身的执行模型链路——你怎么跑 Claude Code，cc-boost 就在它旁边附加检查与门控。

### 免 key 安装（Layer A）

直接在项目里初始化：

```text
/cc-init
/cc-doctor
```

正常让 Claude Code 写代码：

```text
修复登录接口在 token 过期时返回 500 的问题
```

这时已经启用：每次 `Edit` 后跑本地 agent-check、按 `.cc-boost/runtime/baseline.json` 识别新增回归、`.cc-boost/runtime/failures.jsonl` 累积、`/cc-compile-lessons` 总结经验。`/cc-task` 也能创建候选并按 review packet + diff 大小排序，只是不会跑跨模型 verifier。

### 配 verifier key 解锁 Layer B（可选）

为了真正的 cross-family 验证，cc-boost 需要一个**不同于执行模型家族**的外部 verifier 模型。推荐配置一个 OpenAI API 格式兼容接口；默认 `protocol=openai_chat`，也就是调用：

```text
POST <CC_BOOST_VERIFIER_BASE_URL>/chat/completions
```

```bash
export CC_BOOST_VERIFIER_BASE_URL="https://your-provider-or-gateway/v1"
export CC_BOOST_VERIFIER_API_KEY="你的 key"
export CC_BOOST_VERIFIER_MODEL="glm-5"

# 可选；默认就是 openai_chat
export CC_BOOST_VERIFIER_PROTOCOL="openai_chat"

# 可选；用于 /cc-doctor 判断是否跨模型家族
export CC_BOOST_VERIFIER_FAMILY="glm"
```

设置后三个必填变量都存在时，`verifier.enabled: "auto"` 会自动启用 verifier；如果 `.cc-boost/config.json` 里显式写了 `verifier.enabled=false`，则以显式关闭为准。复杂任务用 Best-of-N：

```text
/cc-task 为 GET /users 增加 cursor pagination --n=2 --budget=medium
```

质量档位：

```text
/cc-budget --mode=light    # 默认：只阻止本次新增回归
/cc-budget --mode=quality  # 高风险任务：启用 verifier + 质量证据排序
/cc-budget --mode=ci       # 发布前：不忽略 baseline，按全量 CI 门禁处理
```

## 包含什么

| 组件 | 类型 | 说明 |
|---|---|---|
| `/cc-init` | slash command | 检测项目、安装 `.cc-boost/agent-check.sh`、写 `.cc-boost/config.json` 和本地规则快照 |
| `/cc-doctor` | slash command | 检查 verifier API 设置、角色分配、hook、agent-check、账本状态 |
| `/cc-task` | slash command | Best-of-N 编码任务；创建候选 worktree、并行跑 candidate、收集质量证据、验证、选 winner、apply diff |
| `/cc-budget` | slash command | 调整 quality mode、N、verifier 开关、节流、预算档位 |
| `/cc-ledger` | slash command | 查看 `.cc-boost/runtime/failures.jsonl` 的失败类型、模型分布和最近记录 |
| `/cc-compile-lessons` | slash command | 把失败账本总结成 `.cc-boost/runtime/lessons.md`，后续 prompt 自动注入 |
| `/cc-bench` | slash command | 在本地 fixture 上比较 bare / harness / bon 三种模式 |
| `cc-boost-verifier` | agent | 只读语义复核 Agent；用于 `/cc-task` 或人工验证场景 |
| `cc-boost-candidate` | agent | `/cc-task` 的候选补丁生成器 |
| `cc-boost-lesson-compiler` | agent | 把重复失败聚类成项目经验 |
| `harness-workflow` | skill | 编码任务的 7 步工作流：读文件、计划、小补丁、验证、final gate |
| `failure-triage` | skill | 指导模型按结构化失败摘要修复 |
| `small-patch` | skill | 控制 diff 大小，避免顺手重构 |
| `PreToolUse` hook | hook | 编辑前阻止大范围覆盖式写入和高风险锁文件改动 |
| `PostToolUse` hook | hook | 编辑后运行 Layer A：`.cc-boost/agent-check.sh`，并按 baseline 区分新增回归 |
| `Stop` hook | hook | 结束前重跑 Layer A；只阻止新增回归，并对非平凡 diff 运行 Layer B verifier |
| `UserPromptSubmit` hook | hook | 注入 `.cc-boost/runtime/lessons.md` 中与当前模型相关的项目经验 |
| `SessionStart` hook | hook | 注入 cc-boost 运行规则和当前角色配置 |

## 工作原理

### 1. Layer A：baseline + regression gate

每次 `Edit`、`Write`、`MultiEdit` 或 `NotebookEdit` 后，`scripts/verify-after-edit.sh` 会运行业务项目里的：

```bash
.cc-boost/agent-check.sh
```

默认模板覆盖 Node、Python、Go、Rust 和 generic 项目。`/cc-init` 会先运行 `scripts/baseline-capture.sh` 记录当前仓库健康状态。之后失败时，`scripts/summarize-failure.sh` 会把原始日志压缩成结构化 JSON：

```json
{
  "type": "ts_error",
  "tool": "tsc",
  "files": ["src/api/user.ts"],
  "summary": "Property 'id' does not exist on type UserDTO",
  "evidence": "<trimmed log>",
  "suggested_focus": "Fix the type errors above..."
}
```

这条记录会追加到 `.cc-boost/runtime/failures.jsonl`。如果它匹配 baseline 且没有触碰失败文件，cc-boost 会放行并提醒模型不要扩大 scope；如果是新增回归，则作为 `additionalContext` 注入回 Claude，让模型按失败摘要做最小修复。

### 2. Layer B：跨模型 verifier

`scripts/final-gate.sh` 在 Claude 准备结束时执行：

```text
Layer A 通过
  -> scripts/diff-classify.sh 判断 diff 是否非平凡
  -> scripts/review-packet.sh 收集风险、scope、测试、调用点、依赖、API 证据
  -> 命中 diff hash 缓存则放行
  -> scripts/run-verifier.sh 直调 verifier provider API
  -> verdict=pass      放行并缓存
  -> verdict=fail      block stop，要求修复
  -> verdict=uncertain 按 verifier.uncertain_action 决定
  -> verifier error    放行但提示用户排查
```

`run-verifier.sh` 支持两类协议：

| 协议 | 适用 provider |
|---|---|
| `openai_chat` | MiniMax、Z.ai/GLM、Moonshot/Kimi、DeepSeek、DashScope/Qwen |
| `anthropic_messages` | Anthropic Claude |

Stop gate 直接按 `.cc-boost/config.json` 里的 `verifier.provider` 和 `verifier.model` 通过 HTTP 调用 verifier，绕开 subagent 的 `model: inherit` 限制。verifier 会同时读取 task、diff、Layer A 日志和 deterministic review packet。要做到真正跨模型，必须配置不同模型族的 verifier API key。

### 3. `/cc-task`：Best-of-N 选最优

`/cc-task` 把复杂任务拆成三个确定性脚本和 N 个并行 candidate Agent：

```text
cc-task-setup.sh
  -> 校验 git 工作区干净
  -> 创建 .cc-boost/runtime/worktrees/<run-id>/cand-N
  -> 写每个候选 brief

cc-boost-candidate agents
  -> 在各自 worktree 中独立生成补丁

cc-task-evaluate.sh
  -> 每个候选跑 agent-check
  -> 每个候选收集 review-packet
  -> 每个候选跑 verifier
  -> 按 verdict、Layer A、quality_score、diff_lines、score 排名

cc-task-apply.sh
  -> 3-way apply winner diff
  -> 清理失败候选 worktree / branch
```

选择规则：

1. 排除 Layer A 失败或 `verdict == "fail"` 的候选。
2. 优先 `pass`，其次 `uncertain`，最后 `skipped`。
3. 同档里选 deterministic `quality_score` 最高。
4. 再选 `diff_lines` 最小。
5. 再用 verifier score 打破平局。

### 4. 失败账本与 lessons

所有 Layer A、final gate、verifier 和 Best-of-N 事件都会写入：

```text
.cc-boost/runtime/failures.jsonl
```

`/cc-compile-lessons` 会调用 `cc-boost-lesson-compiler`，把重复失败聚类成：

```text
.cc-boost/runtime/lessons.md
```

`scripts/inject-lessons.sh` 会在后续 prompt 中只注入 `## all` 和当前 executor 模型对应章节，避免上下文膨胀。

## 配置

`.cc-boost/config.json` 由 `/cc-init` 创建，可手动编辑：

```json
{
  "enabled": true,
  "executor": {
    "id": "minimax-m27",
    "provider": "minimax",
    "family": "minimax",
    "model": "MiniMax-M2.7"
  },
  "verifier": {
    "id": "cc-boost-verifier",
    "provider": "cc-boost-verifier",
    "family": "glm",
    "model": "glm-5",
    "protocol": "openai_chat",
    "base_url": "https://your-provider-or-gateway/v1",
    "api_key_env": "CC_BOOST_VERIFIER_API_KEY",
    "enabled": "auto",
    "min_files": 1,
    "min_lines": 20,
    "uncertain_action": "allow",
    "cache_ttl_days": 7
  },
  "summarizer": {
    "id": "minimax-m27-fast",
    "provider": "minimax",
    "family": "minimax",
    "model": "MiniMax-M2.7-highspeed"
  },
  "fallback": {
    "id": "claude-opus-47",
    "provider": "anthropic",
    "family": "claude",
    "model": "claude-opus-4-7"
  },
  "longctx": {
    "id": "kimi-k2",
    "provider": "moonshot",
    "family": "kimi",
    "model": "kimi-k2"
  },
  "verify": {
    "throttle_seconds": 8
  },
  "final_gate": {
    "max_blocks": 3
  },
  "quality": {
    "mode": "light",
    "regression_only": true,
    "preflight": true,
    "full_check_risk": "high"
  },
  "best_of_n": {
    "default_n": 2,
    "budget": "medium"
  }
}
```

`api_key_env` 只记录环境变量名，不保存 key 明文。默认 verifier 协议是
`openai_chat`，表示 OpenAI API 格式：
`POST <base_url>/chat/completions`。多数 OpenAI-compatible 网关只需要设置：

```bash
export CC_BOOST_VERIFIER_BASE_URL="https://your-provider-or-gateway/v1"
export CC_BOOST_VERIFIER_API_KEY="你的 key"
export CC_BOOST_VERIFIER_MODEL="glm-5"
```

旧版 provider preset 仍保留兼容，但新项目建议使用上面的通用 verifier
变量，避免用户记不同厂商的 key 名和 base URL。

## 环境要求

| 依赖 | 用途 |
|---|---|
| Claude Code | 插件、hook、slash command、subagent 运行环境 |
| `bash` | 所有脚本运行时 |
| `jq` | 配置读取、JSON 输出、ledger 处理 |
| `curl` | `run-verifier.sh` 直调 verifier provider |
| `git` | diff hash、worktree、Best-of-N 候选隔离 |
| 项目自己的工具链 | `npm` / `pytest` / `go test` / `cargo` 等由 `agent-check.sh` 调用 |

插件本身不需要 Node/Python runtime，但你的业务项目测试工具仍然需要正常安装。

## 初始化产物

`/cc-init` 会在业务项目写入：

```text
.cc-boost/config.json
.cc-boost/agent-check.sh
.cc-boost/CLAUDE.md
.cc-boost/runtime/baseline.json
.cc-boost/runtime/failures.jsonl
.cc-boost/runtime/lessons.md
.cc-boost/runtime/state/
.cc-boost/runtime/review-packets/
.gitignore 中的 .cc-boost/
```

`/cc-task` 运行时还会创建：

```text
.cc-boost/runtime/worktrees/<run-id>/
```

整个 `.cc-boost/` 默认作为本地 harness 状态忽略，不进入业务 git diff。`failures.jsonl`、`lessons.md`、review packet 和 verifier 响应都可能包含内部路径、日志或业务术语，默认不提交；团队需要共享时应显式导出。

## 命令速查

| 命令 | 何时使用 |
|---|---|
| `/cc-init` | 第一次在项目中启用 cc-boost |
| `/cc-doctor` | 初始化后、换 provider 后、verifier 不工作时 |
| `/cc-task <task>` | 复杂、高风险、容易单次失败的编码任务 |
| `/cc-budget --budget=high` | 想提高候选数量或更严格 verifier 时 |
| `/cc-ledger --limit=20` | 查看最近失败和模型错误分布 |
| `/cc-compile-lessons` | 失败积累一段时间后总结成项目经验 |
| `/cc-bench` | 在自己的 provider 栈上验证 harness 是否有收益 |

## 文件结构

```text
cc-boost/
  .claude-plugin/
    plugin.json
    marketplace.json
  hooks/
    hooks.json
  commands/
    cc-init.md
    cc-doctor.md
    cc-task.md
    cc-budget.md
    cc-ledger.md
    cc-compile-lessons.md
    cc-bench.md
  agents/
    cc-boost-verifier.md
    cc-boost-candidate.md
    cc-boost-lesson-compiler.md
  skills/
    harness-workflow/SKILL.md
    failure-triage/SKILL.md
    small-patch/SKILL.md
  scripts/
    preflight-guard.sh
    verify-after-edit.sh
    final-gate.sh
    baseline-capture.sh
    classify-failure.sh
    failure-fingerprint.sh
    quality-evidence.sh
    review-packet.sh
    run-verifier.sh
    diff-classify.sh
    cc-task-setup.sh
    cc-task-evaluate.sh
    cc-task-apply.sh
    cc-bench-init.sh
    cc-bench-oracle.sh
    summarize-failure.sh
    inject-lessons.sh
    session-bootstrap.sh
    cc-init-detect.sh
    cc-init-probe.sh
    cc-doctor.sh
    show-ledger.sh
  lib/
    common.sh
    registry.sh
    safety.sh
  templates/
    CLAUDE-block.md
    agent-check/
      node.sh
      python.sh
      go.sh
      rust.sh
      generic.sh
```

## 安全与副作用

cc-boost 会执行真实操作，不仅仅修改提示词。它会：

- 运行 `.cc-boost/agent-check.sh`。
- 写入 `.cc-boost/runtime/*`。
- 失败时追加 `.cc-boost/runtime/failures.jsonl`。
- Stop 阶段可能阻止 Claude Code 结束回答。
- `/cc-task` 会创建 git worktree 和临时分支，并在 winner 选出后 apply diff。

安全边界：

- `/cc-task` 要求用户工作区干净，不自动 stash 或 reset。
- `lib/safety.sh` 校验 run-id、路径和分支命名，限制 cleanup 只能发生在 `.cc-boost/runtime/worktrees/<run-id>/`。
- verifier API 故障不会阻死会话；只会提示用户运行 `/cc-doctor`。
- 真正副作用大小取决于你项目的 `.cc-boost/agent-check.sh` 做了什么。请确保测试命令幂等，且不会污染外部资源。

## 当前边界

- 跨模型能力依赖外部 verifier API。没有 `CC_BOOST_VERIFIER_BASE_URL`、`CC_BOOST_VERIFIER_API_KEY`、`CC_BOOST_VERIFIER_MODEL` 时只运行本地 Layer A，`/cc-doctor` 会用中文提示 OpenAI API 格式配置方式。
- `cc-boost-verifier` subagent 仍是 `model: inherit`，真正 Stop gate 跨模型走的是 `scripts/run-verifier.sh`。
- `/cc-compile-lessons` 由 lesson compiler Agent 完成失败聚类，质量取决于该模型的输出，本地无 Bash 兜底。
- `/cc-bench` 生成本地 fixture，但实际求解仍依赖 Claude Code Agent 能力和你的 provider 质量。

## License

MIT. See [LICENSE](LICENSE).
