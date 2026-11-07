# edgetunnel

单文件 Cloudflare Worker 代理服务，支持 VLESS、Trojan、Shadowsocks、管理面板与订阅生成。全部 Worker 逻辑在 `_worker.js`，无构建步骤或仓库内测试套件。

## 按任务读取

- **改协议解析或代理链**：读 `_worker.js` 的 `处理WS请求`、`处理gRPC请求`、`处理XHTTP请求`、`socks5Connect`、`httpConnect` 与 `反代参数获取`。首包解析手写字节偏移，修改时逐字段核对协议边界。
- **改配置或订阅**：读 `读取config_JSON`，环境变量、KV 配置和运行时参数的合并顺序以该函数为准，不在本文件另维护完整变量表。
- **改管理面板**：Worker 只提供后端；前端在运行时从 `Pages静态页面` 指向的 `https://edt-pages.github.io` 获取。
- **改部署或同步**：同时检查 `wrangler.toml` 与 `.github/workflows/sync.yml`。fork 每日同步上游，需保留本 fork 与 `cmliu/edgetunnel` 的实际差异，不能用上游 README 替代本地部署事实。

本仓当前行为按「`_worker.js` 与 `wrangler.toml` > 本仓实际部署回执 > fork 差异说明 > 上游 README > `docs/superpowers` 历史计划」判断。上游部署步骤不能直接套到本 fork；历史 plan 只用于追溯，不自动授权改协议、配置或同步行为。

## 常用命令

```bash
bunx wrangler dev
bunx wrangler deploy    # 实际部署；需要明确授权
bunx wrangler tail
```

本地管理功能需要 `ADMIN` secret 和 binding 为 `KV` 的命名空间。`UUID`、`PROXYIP` 等其他配置按 `读取config_JSON` 的当前契约设置。

## 修改边界

- `_worker.js` 直接部署，修改必须保持 Cloudflare Workers JavaScript 与 `cloudflare:sockets` 可用；不要引入需要 bundler 的依赖。
- 兼容性日期以 `wrangler.toml` 为准。
- 没有测试套件时，按改动范围报告实际验证过的协议、管理或订阅路径；Wrangler 能启动不等于代理链路已验证。
