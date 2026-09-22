# CodexStats

macOS 菜单栏小工具，展示 Codex 与 Claude Code 的 token 用量和费用。

## 功能

- 菜单栏常驻显示今日 token 总量与金额
- 点击展开面板：
  - 今日、近 7 天按模型汇总（输入 / 输出 / 缓存 / 金额）
  - 今日会话 Top 5（按 token 倒序，带各自费用）
- 金额按 DeepSeek 官方定价计算，区分 flash / pro 两档模型
- 面板支持小 / 中 / 大三档字号，选择会被记住

## 数据来源

| 来源 | 路径 |
| --- | --- |
| Codex 会话 | `~/.codex/sessions/**/*.jsonl` |
| Claude Code 会话 | `~/.claude/projects/**/*.jsonl` |
| Codex 会话标题 | `~/.codex/session_index.jsonl` |

Claude Code 会把同一个响应重复写入多行，统计时按 `message.id` 去重；子代理记录（`<会话>/subagents/agent-*.jsonl`）归入其主会话。

## 构建

只需要 Command Line Tools，不需要完整 Xcode：

```bash
./build.sh
open CodexStats.app
```

## 调试

```bash
# 以纯文本形式打印面板内容，便于核对统计口径
CodexStats.app/Contents/MacOS/CodexStats --dump
```

## 发布

推送形如 `v1.0.0` 的 tag 会触发 GitHub Actions：构建 app、打包 zip、并创建对应版本的 Release，Release 说明里包含自上一个 tag 以来的提交列表与代码改动统计。
