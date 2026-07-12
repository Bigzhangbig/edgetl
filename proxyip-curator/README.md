# proxyip-curator

定时自动获取、测试、整理 CF proxyIP,结果上传到 GitHub Gist。每轮先复测已有条目,失败即剔除;再拉新源、探测、合并、按延迟排序、截断上传。

## 体积

Alpine 3.20 + curl + jq + bash,~15MB。

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `GIST_TOKEN` | ✓ | GitHub PAT,scope=`gist` |
| `GIST_ID` | ✓ | 目标 gist id |
| `GIST_FILENAME` | | gist 内文件名,默认 `proxyip.json` |
| `SOURCES` | | 逗号分隔的 IP 列表源 URL,默认 `https://zip.cm.edu.kg/all.json` |
| `CHECKER_API` | | 探测 API,默认 `https://api.090227.xyz/check` |
| `REGION_FILTER` | | 仅保留匹配 `#TAG` 的行,如 `JP,US,HK` |
| `MAX_KEEP` | | 单次保留上限,默认 200 |
| `PROBE_TIMEOUT` | | 单次探测超时秒,默认 12 |
| `PROBE_CONCURRENCY` | | 并发,默认 20 |
| `INTERVAL_SEC` | | 循环间隔秒,默认 1800 (30min)。本地 15h × 86 IP 稳定性测试:30min 内累计新失败 <2%,6h 会累计到 ~6%。加密可选 900(15min,~<1%)或 3600(1h,~3%)。 |

## 本地构建(orbstack,用清华镜像)

```bash
cd proxyip-curator
docker build \
  --build-arg APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine \
  -t proxyip-curator:local .
```

## GitHub 编译(不用镜像)

推 `proxyip-curator/**` 触发,产物推到 `ghcr.io/<owner>/proxyip-curator:latest`。

## 运行

```bash
docker run -d --name proxyip-curator --restart=unless-stopped \
  -e GIST_TOKEN=ghp_xxx \
  -e GIST_ID=abcdef1234567890 \
  -e SOURCES="https://zip.cm.edu.kg/all.json" \
  -e REGION_FILTER=JP,HK,SG \
  -e MAX_KEEP=100 \
  -e INTERVAL_SEC=1800 \
  proxyip-curator:local
```

一次性:`docker run --rm -e ... proxyip-curator:local once`。

## Gist 数据格式

```json
[
  {"proxy":"1.2.3.4:443","v4":true,"v6":false,"ms":160,"colo":"AMS"},
  ...
]
```

按 `ms` 升序,长度 ≤ `MAX_KEEP`。

## 流程

1. 拉当前 gist → 复测每条 → 剔除 `success!=true`
2. 拉 `SOURCES` → 去重 → 排除本轮已测
3. 探测新候选
4. 合并存活的旧条目 + 通过的新条目 → 按延迟排序 → 截断 `MAX_KEEP`
5. PATCH gist
6. 回读 gist 确认

> 若某轮合并结果为 0,保留原 gist(避免 API 抽风清空)。

skipped: 死信队列、失败原因分类、Prometheus 指标 — 加当此工具的日常运维需求超过 grep 日志。
