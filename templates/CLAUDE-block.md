<!-- 下面这块由 cc-boost 管理。标记块之外的内容可自由编辑。 -->

# 编码加固框架（cc-boost）

你正在 Claude Code 中运行，开启了验证器门控加固。本会话的执行模型是
**{{EXECUTOR}}**。项目类型：**{{PROJECT_TYPE}}**。
跨模型验证器：**{{VERIFIER}}**。

## 工作流（强制）

1. **Inspect** —— 编辑前先阅读相关文件。在计划中引用具体文件路径。
2. **Plan** —— 任何涉及 ≥2 个文件的改动，先用不超过 5 行说明你将修改哪些
   文件、为什么。
3. **Patch** —— 小步、聚焦地编辑。不要顺手重构无关代码。
4. **Verify** —— 每次编辑后，PostToolUse 钩子会运行
   `scripts/agent-check.sh`，失败时把结构化的失败摘要回灌给你。修复时只读
   被引用的文件，不要扩大范围。
5. **Stop-gate** —— 你尝试结束本轮时，Stop 钩子会再次跑 agent-check。
   失败则不能结束。同一个错误连续两次，请退一步换思路，而不是继续打补丁。
6. **Cross-model verify** —— 对非平凡 diff（≥3 个文件或 ≥80 行），在宣告
   完成前调用 `cc-boost-verifier` 子代理。它在语义正确性上的裁决具有权威性。
7. **Best-of-N** —— 困难任务优先用 `/cc-task "…"` 而不是自由提问。它会用
   不同模型生成 N 个候选，并挑选 diff 最小且通过验证的那个。

## 失败账本

每次 Layer A 或 Layer B 失败都会被追加到 `.cc-boost/failures.jsonl`。
定期运行 `/cc-compile-lessons` 把账本提炼为按项目分级的规则
（写入 `.cc-boost/lessons.md`），并在每次 prompt 时被注入。

## 不要做的事

- 不要禁用 lint/test 让检查通过。
- 不要为了吞掉错误而加 try/except。
- 未经用户明确要求，不要引入新依赖。
- 未经要求，不要写文档文件。
- 不要写只是复述代码的注释。

<!-- cc-boost:end-managed -->
