# proxyIP IPv4 出口治理设计

**日期：** 2026-08-29

## 目标

解决 US 节点访问 Cloudflare CDN 时偶发出现 IPv6 出口的问题。系统需要做到：

1. 从 `zip.cm.edu.kg` 读取的候选地址经过严格格式化和地址族校验。
2. curator 更新 Gist 时淘汰历史 IPv6 条目，而不是因为旧条目复测成功就继续保留。
3. Worker 在没有显式 `proxyip=` 的节点上，不从完整池随机选择未确认的 IPv6 条目。
4. `egress=v4/v6` 只有在探测请求确实经过 proxyIP 时才有意义；直接 `curl --resolve` 只能判断候选地址的入站地址族和可用性。

## 已确认的事实

- 当前 `all.txt` 和 `all.json` 快照均只包含 IPv4 候选。
- `all.json` 位于顶层 `data` 数组，包含 `ip`、端口数组和 `meta.colo.iata`，比 `all.txt` 更适合进行 LAX/NRT/AMS 等同区匹配。
- 当前订阅的 US 节点没有显式 `proxyip=`，因此会进入 Worker 的运行时默认选池逻辑。
- `_worker.js` 的运行时默认选池目前使用 `Math.random()` 从完整 proxyIP 池取值，没有检查 `v4` 或 `egress`。
- curator 当前的 `egress` 字段来自探测机直接访问 Cloudflare 后的 trace `ip=`，不能代表 proxyIP 后端的出站地址。

## 方案边界

### 必须保证

- curator 产出的 `proxy` 使用明确的 `IPv4:port` 格式。
- 旧 Gist 中的 IPv6 不得在严格 IPv4 模式下进入下一轮合并结果。
- `all.json` 中的多个端口都能参与候选探测，不因只取第一个端口造成不必要的 LAX 候选缺失。
- Worker 运行时至少只选择字面量 IPv4 候选；若有可信的 `egress=v4` 元数据，则优先使用它。
- 没有 IPv4 候选时，不静默选择 IPv6；应回退到内置默认路径并保留可观测的失败原因。

### 明确不保证

- 仅凭 `zip.cm.edu.kg` 的 `ip` 字段无法证明目标网站最终看到的出口地址族。
- 仅凭 Cloudflare `colo` 或节点备注中的 `[LAX]` 无法保证每次请求都在同一 Cloudflare POP。
- 未经真实代理链路验证的 `egress` 字段不参与“目标 CDN 出口 IPv4”结论。

## 数据流

```text
zip all.json/all.txt
        ↓
地址和端口规范化、IPv4 过滤、IATA 保留
        ↓
候选探测：可用性 + 入站地址族；真实 egress 仅接受可信检查器结果
        ↓
Gist：去重、清理旧 IPv6、按 IATA 保留候选
        ↓
Worker：IATA 优先；无显式 proxyip 时只从 IPv4 候选运行时选择
        ↓
US VLESS 节点 → Cloudflare /cdn-cgi/trace 重复验证
```

## 具体设计

### curator

- 默认继续使用 `all.json`。
- 解析 `data[]` 中的 `ip` 和完整端口数组；IPv4 输出为 `ip:port`，IPv6 若在非严格模式下保留则必须输出为 `[ip]:port`。
- 增加严格 IPv4 模式，默认开启；来源候选和旧 Gist 候选均经过同一个过滤器。
- 候选截断按 IATA 分层，先确保每个出现的 IATA 至少保留一个候选，再用剩余配额填充，避免 LAX 在全局随机截断中消失。
- 直接 Cloudflare `--resolve` 探测只写入 `v4/v6` 和可用性；`egress` 默认为空。只有配置的可信检查器明确返回代理链路出口时，才写入 `egress`。
- 合并前过滤历史 Gist，避免历史 IPv6 因复测成功继续存活。

### Worker

- 将运行时默认池选择改为纯策略：可信 `egress=v4` 候选优先，其次字面量 IPv4 候选；无 IPv4 候选时保留内置默认路径，不选择 IPv6。
- 保留现有 IATA 选择逻辑，但让字面量 IPv4 过滤成为最后一道防线。
- 不改变 VLESS、WebSocket、TLS、ECH 协议格式。

## 错误处理

- 源数据为空、JSON 结构不支持或所有候选均失败：curator 不覆盖已有 Gist。
- IPv6 候选被过滤时记录数量统计，不记录完整 proxy 地址。
- 真实 egress 检查器超时或返回不完整时将 `egress` 置空，不把失败误判为 `v4`。
- Worker 池没有可用 IPv4 候选时沿用默认路径，并在日志中只记录 `family=v4-unavailable` 等地址族信息，避免泄露完整池内容。

## 验证标准

1. 纯函数测试覆盖 IPv4、带端口 IPv6、无端口地址、多个端口和旧 Gist 清理。
2. `all.json` fixture 能产出带 IATA 的 IPv4 候选，`all.txt` fixture 能产出带国家标签的 IPv4 候选。
3. curator 合并结果中不存在 IPv6 `proxy`，且 LAX 至少有一个候选时不会被全局截断丢弃。
4. Worker 运行时选择测试证明池中同时存在 IPv4/IPv6 时永不返回 IPv6；存在 `egress=v4` 时优先返回该子集。
5. 使用订阅中的 US 节点建立临时本地 SOCKS 出口，重复请求 Cloudflare `/cdn-cgi/trace`，成功响应的 `ip=` 均为 IPv4；失败节点单独记录，不与地址族结果混淆。
