<!-- 下面这块由 cc-boost 管理。标记块之外的内容可自由编辑。 -->

# 编码加固框架（cc-boost）

你正在 Claude Code 中运行，开启了质量闭环加固。本会话的执行模型是
**{{EXECUTOR}}**。项目类型：**{{PROJECT_TYPE}}**。
跨模型验证器：**{{VERIFIER}}**。

## 工作流（强制）

1. **Inspect** —— 编辑前先阅读相关文件。在计划中引用具体文件路径。
2. **Plan** —— 任何涉及 ≥2 个文件的改动，先用不超过 5 行说明你将修改哪些
   文件、为什么。
3. **Patch** —— 小步、聚焦地编辑。不要顺手重构无关代码；不要用 Write 覆盖
   已存在源码文件。
4. **Regression gate** —— 每次编辑后会运行 `.cc-boost/agent-check.sh`。已记录的
   baseline 失败不是本轮必须修复的目标；新增失败必须修。
5. **Stop-gate** —— 结束前重跑检查。只有新增回归会阻止结束；历史失败会记录
   但不应扩大任务范围。
6. **Quality review** —— 对非平凡 diff，验证器会结合 diff、检查日志和
   review packet 的风险、测试和调用点信号审查语义正确性、回归风险、scope 与可维护性。
7. **Best-of-N** —— 困难任务优先用 `/cc-task "…"` 而不是自由提问。它会用
   多个候选，并挑选通过验证、质量分最高、diff 最小的那个。

## 失败账本

每次 Layer A 或 Layer B 失败都会被追加到 `.cc-boost/runtime/failures.jsonl`。
定期运行 `/cc-compile-lessons` 把账本提炼为按项目分级的规则
（写入 `.cc-boost/runtime/lessons.md`），并在每次 prompt 时被注入。

## 不要做的事

- 不要禁用 lint/test 让检查通过。
- 不要为了吞掉错误而加 try/except。
- 未经用户明确要求，不要引入新依赖。
- 未经要求，不要写文档文件。
- 不要写只是复述代码的注释。
