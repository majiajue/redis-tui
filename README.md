# Redis TUI

Browse and troubleshoot Redis Cluster from a read-only-first terminal console. Find keys by prefix, page through collections, and rank memory-heavy keys within a bounded sample. Available for Bash and native Windows PowerShell.

[中文快速上手](#中文快速上手) · [Download Windows ZIP](./redis-tui-powershell.zip?raw=true)

![Redis TUI key search and big-key ranking, captured from a disposable Redis cluster](docs/preview.png)

## Quick start

**Windows** · Download and extract the ZIP, then run `redis-tui.cmd`. This launcher uses Windows PowerShell and connects directly to Redis. The terminal prompts are in Chinese.

**Linux, WSL, or macOS** · Install Bash 4+ and `redis-cli`, then run the following. Bash TLS also requires Python 3. On macOS, use a Bash 4+ installation in place of the system Bash.

```bash
git clone https://github.com/majiajue/redis-tui.git
cd redis-tui
REDIS_CLI="$(command -v redis-cli)" bash bin/redis-tui.sh
```

Enter a Redis Cluster endpoint and credentials at the prompt. Start with `2` to search for a known prefix, or open `3` → `4` for Big Key Ranking.

## What you can do

| Task | Controls |
| --- | --- |
| Find keys | Use `2` for search, then filter by type or prefix, or show only non-expiring keys. Searches default to 2,000 results and 15 seconds. Press `r` to refresh or `q` to stop a running search. |
| Inspect collections | View Hash, Set, List, ZSet and Stream values in pages. Use `<` and `>` to navigate. In a Hash, `f` filters field names by literal text. |
| Investigate high memory use | Open `3` → `4`. Choose one or all primaries and a literal prefix, then set the per-node sample size and Top N. Use `s` to see each node's sample and measurement counts. The rank covers the measured sample. |
| Check cluster health | Open `3` for the cluster overview, slow queries, and command and error statistics. |
| Reuse connections | Open `4` for named profiles with ACL usernames and TLS. TLS verifies the certificate name and supports system trust or a custom PEM CA. Passwords are entered at connection time and kept in the running session. |

New sessions start in read-only mode. When deletion is needed, enable writes for the current connection with `5` and `WRITE`. The deletion preview requires a separate `YES` confirmation.

Saved profiles can be opened with `bash bin/redis-tui.sh --profile "name"` or `.\powershell\redis-tui.cmd -Profile "name"`. Set `REDIS_TUI_CONFIG_DIR` to choose a profile directory.

## 中文快速上手

1. Windows 下载并解压 [PowerShell ZIP](./redis-tui-powershell.zip?raw=true)，双击 `redis-tui.cmd`。Linux、WSL 和 macOS 按上方 Bash 命令启动。
2. 输入 Redis Cluster 节点、端口和凭据。需要重复使用时，按提示给连接命名。主菜单 `4` 可以切换已保存的配置。
3. 按 `2` 查 Key。输入结果序号查看详情，用 `<`、`>` 翻页，Hash 详情按 `f` 筛选字段名。
4. 按 `3` → `4` 查看大 Key 排行。可按主节点和前缀采样，按 `s` 核对覆盖范围和成功测量数。

集成测试使用 Bash 5.2、PowerShell 7.4 和本机 Redis 7.4 集群。Windows PowerShell 5.1 和 WSL 启动器待实机验证。
