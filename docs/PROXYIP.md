# PROXYIP 地址族策略

## 输入与清洗

`https://zip.cm.edu.kg/all.json` 是首选输入：它包含 `data[].ip`、完整的 `port[]` 以及 `meta.colo.iata`。`all.txt` 也支持，但通常只有地址和国家标签。

curator 默认只生成严格的 `IPv4:port` 条目：

- IPv4 的四个八位组必须在 `0-255` 范围内。
- 端口必须在 `1-65535` 范围内。
- JSON 中的端口数组会全部展开，不再只取第一个端口。
- IPv6、非法地址、非法端口和历史 Gist 中的 IPv6 会在合并前清理。
- 候选达到探测上限时，先按 IATA 至少保留一个，再随机补齐剩余名额。

## `egress` 字段语义

curator 的 `curl --resolve` 只证明“从当前探测机连接到这个候选地址可用”，Cloudflare trace 中的 `ip=` 是探测机出口，不能当作 proxyIP 后端的真实出口。因此直接探测不会自动填写 `egress`。

只有明确经过 proxyIP 链路的可信检查器，在返回以下结构时才允许写入 `egress`：

```json
{"success":true,"egress_ip":"198.51.100.10"}
```

`egress_ip` 为 IPv4 时写入 `egress: "v4"`，为 IPv6 时写入 `egress: "v6"`；检查失败或字段缺失时留空。配置 `CHECKER_API` 前，应确认该服务确实使用 `proxyip` 参数建立代理链路，而不是从检查器自身直接访问 Cloudflare。

## Worker 选择顺序

Worker 消费池时再次验证字面量 `IPv4:port`。有可信 `egress: "v4"` 时优先使用这些条目，否则从其余字面量 IPv4 中选择；IPv6 不会因为 `v4: true` 等旧元数据而被放行。池中没有安全 IPv4 候选时，保留内置默认路径，不静默挑选 IPv6。

节点备注里的 `[LAX]`、Gist 的 `colo` 和 Cloudflare 的 `colo` 是匹配/观测信息，不等于固定的目标 CDN 出口位置。上线验证应通过真实 US 节点重复请求 `/cdn-cgi/trace`，记录成功/失败、`ip` 地址族和 `colo`，不要只依据节点备注判断。
