# proxyIP IPv4 出口治理实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 清理 `zip.cm.edu.kg` 候选池中的地址族问题，阻止 Worker 运行时随机选择 IPv6，并用真实 US 节点链路验证 Cloudflare 看到的出口地址族。

**架构：** curator 负责源数据解析、IPv4 严格过滤、旧 Gist 清理和 IATA 分层保留；Worker 负责消费池时的 IPv4 防线。直接 `--resolve` 探测只判断候选入站地址族，真实 egress 只有在可信检查器经过代理链路返回时才写入。

**技术栈：** Bash、jq、Node.js 纯函数测试、Cloudflare Worker 单文件 `_worker.js`、Xray 临时链路测试。

---

## 文件结构

- 修改：`proxyip-curator/run.sh` — 源数据解析、IPv4 过滤、端口展开、IATA 分层截断、Gist 合并和探测字段语义。
- 创建：`proxyip-curator/lib.sh` — 可在 Bash 测试中复用的地址格式化和地址族判断函数。
- 创建：`proxyip-curator/tests/fixtures/source.json` — 覆盖 `all.json` 的 `data[].ip + port[] + meta.colo.iata` 结构。
- 创建：`proxyip-curator/tests/fixtures/source.txt` — 覆盖 `all.txt` 的 IPv4 与国家标签结构。
- 创建：`proxyip-curator/tests/fixtures/current-gist.json` — 覆盖旧 IPv4、旧 IPv6、无效地址和 IATA 元数据。
- 创建：`proxyip-curator/tests/test_proxyip.sh` — 离线回归测试入口。
- 修改：`_worker.js` — 运行时默认 proxyIP 选择的 IPv4/可信 egress 筛选。
- 修改：`docs/PROXYIP.md` — 记录严格 IPv4 模式、`egress` 语义和验证方式。

### 任务 1：建立离线失败测试

**文件：**
- 创建：`proxyip-curator/lib.sh`
- 创建：`proxyip-curator/tests/fixtures/source.json`
- 创建：`proxyip-curator/tests/fixtures/source.txt`
- 创建：`proxyip-curator/tests/fixtures/current-gist.json`
- 创建：`proxyip-curator/tests/test_proxyip.sh`

- [ ] **步骤 1：编写 fixture 和失败断言**

`source.json` 至少包含一个 IPv4 地址、一个规范化的 `[IPv6]:port`、一个含三个端口的 IPv4 地址，以及 `LAX`/`NRT` 两个 IATA。测试入口先 source `lib.sh`，再调用任务 2 定义的 `normalize_json_candidates`、`filter_ipv4_proxy` 和 `filter_json_ipv4_entries`。

```bash
mapfile -t got < <(normalize_json_candidates "$fixture_dir/source.json" | awk -F '\t' '{print $1}' | sort)
assert_lines got "203.0.113.10:2053" "203.0.113.10:443" "203.0.113.10:8443"
assert_false "filter_ipv4_proxy '[2001:db8::10]:443'"
assert_true "filter_ipv4_proxy '203.0.113.10:443'"
assert_no_ipv6 < <(filter_json_ipv4_entries "$fixture_dir/current-gist.json")
```

- [ ] **步骤 2：运行测试验证当前实现缺失能力**

运行：

```bash
bash proxyip-curator/tests/test_proxyip.sh
```

预期：失败，至少指出 `lib.sh` 不存在或 IPv6/多端口断言未满足。失败输出不得打印完整地址池。

- [ ] **步骤 3：Commit 测试基线**

```bash
git add proxyip-curator/tests proxyip-curator/lib.sh
git commit -m "test: define proxyip IPv4 pool invariants"
```

### 任务 2：实现 curator 地址清洗与池清理

**文件：**
- 修改：`proxyip-curator/lib.sh`
- 修改：`proxyip-curator/run.sh:136-174`
- 修改：`proxyip-curator/run.sh:221-260`

- [ ] **步骤 1：实现最小纯函数**

实现以下 Bash 函数，函数只输出规范化结果或布尔值，不输出完整地址池：

```bash
is_ipv4_proxy() {
  local value="${1%%#*}" host
  host="${value%:*}"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  awk -F. '{for (i=1;i<=4;i++) if ($i > 255) exit 1}' <<<"$host"
}

format_proxy() {
  local ip="$1" port="$2"
  if [[ "$ip" == *:* ]]; then
    printf '[%s]:%s\n' "${ip#[}" "${port:-443}"
  else
    printf '%s:%s\n' "$ip" "${port:-443}"
  fi
}
```

`is_ipv4_proxy` 必须拒绝 IPv6、非法八位组、缺少端口和混入备注的地址；备注在进入判断前单独剥离。

同时实现 `normalize_json_candidates file` 和 `filter_json_ipv4_entries file`：前者输出 `proxy<TAB>country<TAB>iata`，后者输入 Gist JSON 并只输出通过 `is_ipv4_proxy` 的 JSON 条目。测试脚本中的 `assert_lines`、`assert_true`、`assert_false` 和 `assert_no_ipv6` 是测试文件内的本地断言函数，不属于生产接口。

- [ ] **步骤 2：让 JSON 解析展开全部端口并支持 `data`**

将 `run.sh` 的 jq 过滤改为遍历 `.data[]`，对每个 `ip` 遍历 `.port[]`，通过 `format_proxy` 或等价 jq 逻辑生成地址；保留 `country` 与 `meta.colo.iata` 到 `.map`，不再只使用第一个端口。

- [ ] **步骤 3：在旧 Gist 合并前应用同一 IPv4 过滤器**

读取 `cur_json` 后先过滤 `proxy` 为严格 IPv4:port 的条目，再进入 retest；这样历史 IPv6 即使 HTTP 探测成功也不会进入 `merged_json`。所有候选为空时继续沿用“保留原 Gist”的保护行为。

- [ ] **步骤 4：运行离线测试确认通过**

运行：

```bash
bash proxyip-curator/tests/test_proxyip.sh
bash -n proxyip-curator/lib.sh proxyip-curator/run.sh
```

预期：所有地址格式、IPv6 清理、多端口展开和旧 Gist 清理断言通过。

- [ ] **步骤 5：Commit curator 清洗改动**

```bash
git add proxyip-curator/lib.sh proxyip-curator/run.sh proxyip-curator/tests
git commit -m "fix: enforce IPv4 proxyip pool hygiene"
```

### 任务 3：修正 egress 字段语义与 IATA 候选覆盖

**文件：**
- 修改：`proxyip-curator/run.sh:23-60`
- 修改：`proxyip-curator/run.sh:216-260`
- 修改：`proxyip-curator/tests/test_proxyip.sh`

- [ ] **步骤 1：为错误的直接探测增加失败测试**

fixture 测试必须验证：没有可信代理链路检查器时，探测结果的 `egress` 为空；候选为 IPv4 时只填 `v4=true`，不得根据直接 Cloudflare trace 的 `ip=` 写入 `egress=v4`。

- [ ] **步骤 2：实现保守的 egress 处理**

保留 `curl --resolve` 作为可用性和候选字面量地址族探测；移除其对 `trace ip=` 的 egress 推断。只有 `CHECKER_API` 或等价可信检查器返回明确的 `egress_ip` 且 `success=true` 时，才设置 `egress=v4/v6`；响应不完整、超时或字段缺失时设置为空。

- [ ] **步骤 3：按 IATA 分层进行候选截断**

在 `MAX_PROBE_CANDIDATES` 限制下先按 IATA 分组，每组至少保留一个候选，再用剩余配额按原有随机策略补齐；这样源站中存在 `LAX` 数据时，不能因为全局随机截断而完全消失。

- [ ] **步骤 4：运行测试和 shell 校验**

运行：

```bash
bash proxyip-curator/tests/test_proxyip.sh
bash -n proxyip-curator/run.sh
```

预期：`egress` 未知时为空，可信 checker fixture 的 `egress_ip` 能正确映射为 v4/v6，IATA 保底断言通过。

- [ ] **步骤 5：Commit egress 语义改动**

```bash
git add proxyip-curator/run.sh proxyip-curator/tests
git commit -m "fix: stop inferring proxy egress from direct probes"
```

### 任务 4：为 Worker 增加运行时 IPv4 防线

**文件：**
- 修改：`_worker.js:45-54`
- 修改：`_worker.js:410-487`
- 修改：`docs/PROXYIP.md`

- [ ] **步骤 1：增加运行时选择回归测试**

在 `proxyip-curator/tests/test_proxyip.sh` 中加入纯选择规则断言，覆盖：

```text
池 = [IPv6, IPv4(egress unknown), IPv4(egress=v4)] → 选择 IPv4(egress=v4)
池 = [IPv6, IPv4(egress unknown)] → 选择 IPv4
池 = [IPv6] → 返回“无 IPv4 候选”，不能返回 IPv6
```

- [ ] **步骤 2：在 Worker 中实现同样的筛选策略**

在默认池分支中按以下顺序筛选：

```js
const egressV4Pool = proxyIPs.filter(item => item.egress === 'v4' && item.v4 === true);
const v4Pool = proxyIPs.filter(item => item.v4 === true || isIPv4ProxyValue(item.proxy));
const safePool = egressV4Pool.length > 0 ? egressV4Pool : v4Pool;
if (safePool.length > 0) {
  默认反代IP = safePool[Math.floor(Math.random() * safePool.length)].proxy;
  默认反代兜底 = false;
}
```

`isIPv4ProxyValue` 必须正确处理 `IPv4:port`，不把端口本身误判为 IPv6；没有安全候选时保留内置默认路径。

- [ ] **步骤 3：保留 IATA 路径的 IPv4 最后防线**

IATA 候选仍按可信 `egress=v4`、字面量 `v4=true`、完整候选的顺序排序，但写入节点路径前再次拒绝 IPv6；不改变 VLESS/WS/TLS/ECH 参数。

- [ ] **步骤 4：补充运维文档**

在 `docs/PROXYIP.md` 说明：

```text
all.json 是首选输入；严格 IPv4 模式会清理旧 Gist IPv6；
egress 只有真实经过 proxyIP 的 checker 才可信；
Cloudflare colo/节点备注不等于目标 CDN 的固定出口位置。
```

- [ ] **步骤 5：运行 Worker 静态检查与选择测试**

运行：

```bash
bash proxyip-curator/tests/test_proxyip.sh
node --check _worker.js
```

预期：选择规则和 JavaScript 语法检查通过。

- [ ] **步骤 6：Commit Worker 防线**

```bash
git add _worker.js docs/PROXYIP.md proxyip-curator/tests
git commit -m "fix: prefer IPv4 proxyip at worker runtime"
```

### 任务 5：真实链路验证与回归审查

**文件：**
- 修改：无
- 测试产物：仅使用 `/private/tmp` 临时文件，不进入仓库

- [ ] **步骤 1：验证源站当前输入**

运行：

```bash
curl -fsSL --compressed https://zip.cm.edu.kg/all.json -o /private/tmp/zip_all.json
curl -fsSL --compressed https://zip.cm.edu.kg/all.txt -o /private/tmp/zip_all.txt
```

预期：解析成功；统计候选字面量 IPv6 为 0；`all.json` 能识别 `data[]`、多端口和 IATA。

- [ ] **步骤 2：验证 curator 输出池**

以 fixture 和脱敏后的本地输入运行一次合并流程，断言：

```text
merged.proxy 中不存在 IPv6
LAX 有候选时至少保留一个 LAX
未知 egress 不被写成 v4
```

- [ ] **步骤 3：通过 US 节点重复访问 Cloudflare trace**

使用临时 Xray 本地 SOCKS 入站，逐条测试订阅 US 节点，至少执行 10 次新连接；解析 Cloudflare `/cdn-cgi/trace` 的 `ip=`，只输出 `family=v4/v6`、成功/失败和 `colo`，不输出 UUID、token 或完整池地址。

预期：成功响应全部 `family=v4`；连接失败单独归类，不能被当作 IPv6。

- [ ] **步骤 4：检查改动范围和敏感信息**

运行：

```bash
git diff --check
git status --short
git diff --stat HEAD~4..HEAD
  rg -n "token=|uuid|password|GIST_TOKEN|PROXY_PREFIX" docs proxyip-curator/tests _worker.js
```

预期：没有订阅 token、UUID、密码或 GitHub secret 进入仓库和测试输出；工作区只包含计划内文件。

- [ ] **步骤 5：Commit 验证记录或交付结果**

若验证全部通过，使用：

```bash
git commit --allow-empty -m "test: verify proxyip IPv4 egress policy"
```

若真实 egress checker 不可用，则不伪造成功结论，记录“候选地址族已验证，目标 CDN 出口仍需可信 checker”并保留工作区供审查。
