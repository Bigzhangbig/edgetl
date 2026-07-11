# edgetunnel ProxyIP 完整文档

> 基于 `_worker.js` (~5941 行) 源码研究整理。适用 cmliu/edgetunnel 及其衍生分支。

## 目录

- [一、ProxyIP 是什么](#一proxyip-是什么)
- [二、配置来源与优先级](#二配置来源与优先级)
- [三、多 IP 支持机制](#三多-ip-支持机制)
- [四、域名解析型 ProxyIP](#四域名解析型-proxyip)
- [五、路径参数注入](#五路径参数注入)
- [六、SOCKS5/HTTP 代理链(替代路径)](#六socks5http-代理链替代路径)
- [七、GO2SOCKS5 分流](#七go2socks5-分流)
- [八、订阅端集成](#八订阅端集成)
- [九、自动化边界](#九自动化边界)
- [十、常见场景配方](#十常见场景配方)
- [十一、故障排查](#十一故障排查)
- [十二、CFST 与 ProxyIP 的关系](#十二cfst-与-proxyip-的关系)
- [十三、稳定获取方案对比](#十三稳定获取方案对比)
- [十四、推荐 Top 5 方案](#十四推荐-top-5-方案)
- [十五、FOFA 等测绘平台挖掘](#十五fofa-等测绘平台挖掘)
- [十六、法律与道德边界](#十六法律与道德边界)

---

## 一、ProxyIP 是什么

### 1.1 官方封锁

Cloudflare 官方文档明确规定[[1]](https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/):

> **Outbound TCP sockets to Cloudflare IP ranges are temporarily blocked, but will be re-enabled shortly.**

("temporarily" 从 2023 至今未解除,视为永久。)

**含义**:Worker 用 `cloudflare:sockets` 的 `connect()` 直接拨号到 CF 自家 IP 段时,连接会被拒。而大量目标(`*.workers.dev`、`chatgpt.com`、`netflix.com`、绝大部分用了 CF 的网站)的边缘 IP **都是 CF 段**,所以 Worker 无法直接访问它们的边缘。

### 1.2 ProxyIP 的角色

ProxyIP = **"反代了 CF 443 端口的第三方 IP"**(非 CF 段)。上面跑着 nginx stream / iptables NAT / gost / haproxy 等 SNI-agnostic 四层转发,把入向 443 字节流原样转给 CF 官方 IP。链路:

```
客户端 ─[CFST 优选 IP: CF anycast]─→ CF 边缘 ─→ Worker ─[ProxyIP: 非CF反代IP]─→ 目标
       ────── 入口链路 ──────                        ────── 出口链路 ──────
       (加速客户端→CF)                                (绕过 Worker 出站封锁)
```

**关键区分**:
- **CFST 优选 IP** = 客户端**入口**用,是 CF 自家 anycast IP,加速国内→CF
- **ProxyIP** = Worker **出口**用,是反代 CF 的第三方 IP,绕开出站封锁

**CFST 优选 IP 不能直接当 ProxyIP**(它就是 CF IP,填了照样被封)。详见 [§ 十二、CFST 与 ProxyIP 的关系](#十二cfst-与-proxyip-的关系)。

**源码位置**:`_worker.js:2038-2051` `forwardataTCP`。先 `connectDirect()` 尝试直连,失败落到 `connecttoPry()` → `解析地址端口(反代IP, host, uuid)` → 拨号候选池。

**不启用后果**:CF 出站封锁场景(访问 CF 托管站点)首次拨号失败即断连,无第二次机会。

---

## 二、配置来源与优先级

单次请求内实际生效的赋值顺序,**高优先级覆盖低优先级**:

| 优先级 | 来源 | 形式 | 生效范围 |
|---|---|---|---|
| **P0** | URL query | `?proxyip=1.2.3.4:443` | 单次请求 |
| **P0** | URL path | `/proxyip=1.2.3.4:443`、`/proxyip.example.com`、`/pyip=xxx`、`/ip=xxx` | 单次请求 |
| **P0** | URL 链式代理 | `/video/<base64>`(UUID 派生密钥加密的完整代理配置) | 单次请求 |
| **P0** | URL SOCKS5/HTTP | `?socks5=user:pass@host:port` 等 | **短路 ProxyIP** |
| **P1** | 环境变量 | `env.PROXYIP=1.2.3.4:443,5.6.7.8:443` | 部署全局,多值随机选一 |
| **P2** | 硬编码 fallback | `${colo}.PROXYIP.7719SsSs.nEt` | 兜底 |

**关键点**:每次进 `处理WS请求`/`处理gRPC请求`/`处理XHTTP请求` 前会调 `反代参数获取(url, userID)` 重赋 `反代IP` 全局变量(`_worker.js:66,70`),所以 URL 参数总能压掉 env。

**决策要点**:
- 想让**同一部署**的不同客户端走不同 proxyIP → 用 URL 参数,让订阅生成器把 `proxyip=xxx` 拼进节点 path
- 想让**整个部署**共享同一 proxyIP → 用 `env.PROXYIP`
- 想让**同一 env** 里塞多个候选并随机 → `env.PROXYIP` 支持逗号/换行分隔

---

## 三、多 IP 支持机制

### 3.1 分隔符

`整理成数组()` (`_worker.js:5172-5178`) 把 `[\t"'\r\n]+` 和 `,+` 都归并为逗号切分。所以 `env.PROXYIP` 里塞:

```bash
# 都合法
env.PROXYIP="1.2.3.4:443,5.6.7.8:443"
env.PROXYIP="1.2.3.4:443
5.6.7.8:443"
env.PROXYIP="1.2.3.4:443  5.6.7.8:443"
```

### 3.2 选取策略

**纯随机,一次一个**(`_worker.js:42-43`):

```js
const proxyIPs = 整理成数组(env.PROXYIP);
反代IP = proxyIPs[Math.floor(Math.random() * proxyIPs.length)];
```

**不支持**:轮询、权重、按国家/ASN 分组、按目标 host 分组。

### 3.3 二次展开(域名池)

单个 proxyIP 值进入 `解析地址端口()` (`_worker.js:5733-5817`) 再切一层:

1. `整理成数组` 再切(允许 P0 层 URL 传逗号列表)
2. 每个条目按类型解析:
   - IPv4/IPv6 字面量 → 直用
   - `.tp<port>` 后缀 → 提取端口(如 `ip.example.com.tp2087` = 端口 2087)
   - 域名 → DoH 查询 **TXT → A → AAAA** 顺序
3. 用 `目标根域名+UUID` 生成**确定性种子**洗牌 → 同目标总打同一 IP,提升 TLS SNI 复用
4. `slice(0, 8)` 限 8 候选

### 3.4 内存缓存

`_worker.js:3` 顶层声明:

```js
let 缓存反代IP;              // 上次输入字符串
let 缓存反代解析数组;         // 上次解析结果 (最多 8 元)
let 缓存反代数组索引;         // 上次成功拨通的下标(粘性)
```

**行为**:同输入命中缓存,直接返回;下次拨号从上次成功的下标继续(粘性轮询)。**Worker 实例存活期间的进程内缓存,冷启动清空**。

### 3.5 并发拨号

`forwardataTCP` 内按 `TCP并发拨号数` 并发拨多个候选,首个握手成功的胜出,其他 abort。默认值搜 `TCP并发拨号数` 即可查到。

---

## 四、域名解析型 ProxyIP

写成 `PROXYIP=proxyip.example.com:443` 时:

1. **不在部署时**解析,每次首用触发 DoH
2. DoH 走 `https://cloudflare-dns.com/dns-query`(自实现 DNS 报文编解码,`_worker.js:4775-4864`)
3. 顺序:
   - **TXT** 优先(`_worker.js:5779`)—— 一条 TXT 可塞多个 IP:port,用 `\n` 或 `\010` 分隔
   - **A** 记录(`_worker.js:5791`)
   - **AAAA** 记录(`_worker.js:5798`)
   - 都没有 → 原样保留域名让 socket 层去解析
4. 结果进 `缓存反代解析数组`

### 4.1 TXT 池语法

公开的 `ProxyIP.US.CMLiussss.net` 就是 TXT 池的实例。用 `dig` 可看:

```bash
dig TXT ProxyIP.US.CMLiussss.net +short
# 返回多行 IP:port,worker 会全部解析
```

### 4.2 `.tp<port>` 后缀

`proxyip.example.com.tp2087` = 「解析出来的所有 IP 全部走 2087 端口」。

**用途**:一个域名池对应非 443 目标端口(如 CF 支持的 2053/2083/2087/2096 等)。

---

## 五、路径参数注入

除了 `?query=` 形式,worker 支持把配置塞进 **URL path 段**,方便订阅生成器把参数嵌入节点 URL。

### 5.1 支持的 path 语法

| Path 形式 | 提取 | 源码行 |
|---|---|---|
| `/proxyip=1.2.3.4:443` | proxyIP | `_worker.js:5578` |
| `/proxyip.example.com` | proxyIP | `_worker.js:5578` |
| `/pyip=xxx` | proxyIP(缩写) | `_worker.js:5578` |
| `/ip=xxx` | proxyIP(缩写) | `_worker.js:5578` |
| `/socks5://user:pass@h:p` | SOCKS5 URL 形式 | `_worker.js:5567-5572` |
| `/socks5=user:pass@h:p` | SOCKS5 参数形式 | `_worker.js:5573-5577` |
| `/gsocks5=xxx` | SOCKS5 强制全局 | `_worker.js:5573-5577` |
| `/http=` / `/https=` / `/turn=` / `/sstp=` | 各类代理链 | `_worker.js:5529-5581` |
| `/video/<base64>` | 链式代理(加密) | `_worker.js:5504-5527` |

### 5.2 完整节点路径拼接

`_worker.js:5029-5045`:

```
${config.PATH}/${代理片段}${最终查询}${?ed=2560 若启用0RTT}
```

- `config.PATH`:基础路径,默认 `/`,可用 `env.PATH` 覆盖
- `代理片段`:优先 SOCKS5 模板,否则 proxyIP 模板
- `最终查询`:客户端自带的 `?xxx=yyy`
- `?ed=2560`:0RTT 早期数据标记(8KB 上限,`_worker.js:7`)

### 5.3 每节点独立 proxyIP

订阅生成时,`_worker.js:434-436` 如果匹配到 `反代IP池` 中的条目:

```js
完整节点路径 = `${config_JSON.PATH}/proxyip=${匹配到的反代IP}`
  .replace(/\/\//g, '/') + (启用0RTT ? '?ed=2560' : '');
```

**实现效果**:同一订阅里不同节点可绑不同 proxyIP,客户端连回来时通过 URL query 生效,达到 P0 优先级。

---

## 六、SOCKS5/HTTP 代理链(替代路径)

**与 ProxyIP 互斥**。当 URL 指定 SOCKS5/HTTP 时,worker 短路 ProxyIP 路径,直接调:

| 协议 | 函数 | 源码行 |
|---|---|---|
| SOCKS5 | `socks5Connect` | `_worker.js:2457` |
| HTTP | `httpConnect` | `_worker.js:2493` |
| HTTPS | `httpsConnect` | `_worker.js:2551` |
| TURN | `turnConnect` | `_worker.js:3459` |
| SSTP | `sstpConnect` | `_worker.js:3646` |

**触发条件**(`_worker.js:2030`):

```js
启用SOCKS5反代 && (启用SOCKS5全局反代 || SOCKS5白名单.some(匹配host))
```

**用法**:URL 里塞 `?socks5=user:pass@host:port` 或 `?socks5=host:port`(无鉴权);path 侧写 `/socks5=xxx` 同效;`/gsocks5=xxx` 强制全局。

---

## 七、GO2SOCKS5 分流

`env.GO2SOCKS5=domain1.com,*.domain2.com` 声明「必须走 SOCKS5」的域名白名单。

**默认内置**(`_worker.js:4`):`*tapecontent.net` 等 Google Scholar/Netflix 载荷 CDN。

**行为**(`_worker.js:47-50` + `2030`):
- 目标 host 命中白名单 → 走 SOCKS5
- 未命中 → 走直连 + ProxyIP
- `GO2SOCKS5=*` → 等价 `globalproxy` query,全走 SOCKS5

**前提**:必须同时配置 SOCKS5 凭据(env 或 URL),否则白名单命中也没法用。

---

## 八、订阅端集成

### 8.1 优选 API 拉取

`请求优选API` (`_worker.js:5286-5497`) 支持三种源格式:

- **CSV 表格**:`IP地址,端口,数据中心`(CloudflareST 输出)
- **CSV 表格**:`IP,延迟,下载速度,数据中心`(带测速)
- **明文/base64**:`ip:port#备注` 逐行

**关键开关**:订阅 URL 加 `?proxyip=true` 才把结果塞进 `反代IP池`(`_worker.js:369,5295,5306,5311,5439,5462,5488`)。

### 8.2 刷新周期

- `SUBUpdateTime=3`(默认 3 小时,`_worker.js:4908`)—— 订阅 subscription-userinfo header 里的过期标记
- **无 cron、无健康检查、无死活剔除**
- worker 只在客户端主动拉订阅时才刷 `反代IP池`

### 8.3 ADD.txt 集成

管理面板 `/admin/getADDAPI` (`_worker.js:120-131`):管理员点「验证」时才拉一次,做一次性健康探测,不做定时循环。

---

## 九、自动化边界

### 9.1 worker 自动做的

- `env.PROXYIP` 多值随机选一,分隔符宽松
- 域名 ProxyIP 的 DoH TXT/A/AAAA 解析、多结果展开
- 目标域名种子确定性洗牌,提升 TLS 连接复用
- 结果内存缓存 + 粘性索引(下次从上次成功的下标续)
- 拨号失败并发试多候选,可选兜底直连(`启用反代兜底`)
- 订阅刷新时把 `proxyip=true` 源的 IP 拼进节点 URL

### 9.2 必须手动/外部做的

- 从检测源(`api.090227.xyz`、`zip.cm.edu.kg`、`ProxyIP.US.CMLiussss.net` 等)**发现最新可用 ProxyIP**
- 写进 `env.PROXYIP` 或 `ADD.txt`
- **判断死活、剔除坏 IP**(worker 不做)
- 定期刷新(worker 无 cron)

**结论**:项目自动化止于「解析 + 随机 + 缓存 + 重试」。「从哪里搞新鲜可用 ProxyIP」完全靠外部输入。本 repo 的 `proxyip-curator/` 就是补这一环。

---

## 十、常见场景配方

### 10.1 最小可用配置

```bash
wrangler secret put ADMIN     # 面板密码
wrangler secret put PROXYIP   # e.g. proxyip.example.com:443
```

### 10.2 多 IP 池 + 域名池混合

```bash
env.PROXYIP="ProxyIP.US.CMLiussss.net,1.2.3.4:443,5.6.7.8.tp2087"
```

3 类混用:域名 TXT 池、IPv4 字面量、`.tp` 端口覆盖。worker 每次请求随机选一个入口,再各自展开。

### 10.3 SOCKS5 兜底 + ProxyIP 主路径

```bash
env.PROXYIP="1.2.3.4:443"
env.GO2SOCKS5="chatgpt.com,*.openai.com,ipinfo.io"
env.SOCKS5="user:pass@sock5.example.com:1080"
```

大部分流量走 ProxyIP,列出的域名强制走 SOCKS5(适合 ProxyIP 到不了的目标)。

### 10.4 每节点独立 ProxyIP(高级)

订阅生成时用带 `?proxyip=true` 的优选 API,worker 会把每个 IP 拼进对应节点 path。客户端更新订阅后每个节点有独立中转。

### 10.5 临时切换测试

不改 env,直接改客户端节点 URL 里的 query:

```
vless://uuid@host:443?path=%2F%3Fproxyip%3D9.9.9.9%3A443&...
```

**优先级 P0**,盖过 env。

---

## 十一、故障排查

### 11.1 症状:节点连上但网页打不开

- 大概率 ProxyIP 死了。用 `https://api.090227.xyz/check?proxyip=<ip>` 验
- `success:false` → 换 IP
- `success:true` 但 `supports_ipv4:false, supports_ipv6:false` → 中转机能响应但无法出站
- `success:true, supports_ipv4:true` 是可用最低标准

### 11.2 症状:偶尔连不上

- 多 IP 池随机选到坏 IP。粘性缓存只对**同一 Worker 实例**生效,冷启动重来
- 减少候选池大小(≤ 4),或用 `proxyip-curator` 定期剔除

### 11.3 症状:改 env.PROXYIP 后不生效

- Worker 冷启动才刷缓存。等 30 秒或触发 `wrangler deploy` 重新部署
- URL 参数会永远盖 env,检查订阅节点 URL 里是不是硬编码了旧值

### 11.4 症状:域名 ProxyIP 解析慢

- 首次 DoH 查询(TXT → A → AAAA 三次)+ 拨号,冷启动可能 500ms+
- 用字面量 IP 更快,但需要外部工具维护列表

### 11.5 症状:CF Worker 免费额度爆掉

- ProxyIP 每次拨号消耗 CPU/subrequest 配额
- 检查是不是启用了兜底直连导致对 CF 自家域名反复重试
- 关闭 `启用反代兜底`,让失败快速返回

---

## 附录:关键源码地图

| 主题 | 函数 | 行 |
|---|---|---|
| 请求入口分派 | `default fetch` | `41-` |
| 参数提取(核心) | `反代参数获取` | `5499-5601` |
| ProxyIP 解析 | `解析地址端口` | `5733-5817` |
| DoH 查询 | `DoH查询` | `4739-4864` |
| 值列表拆分 | `整理成数组` | `5172-5178` |
| TCP 转发 | `forwardataTCP` | `1871-2052` |
| 反代拨号 | `connecttoPry` | `1970-2012` |
| SOCKS5 拨号 | `socks5Connect` | `2457` |
| 优选 API | `请求优选API` | `5286-5497` |
| 节点路径拼接 | (匿名) | `5029-5045` |

---

**文档基于源码研究,若未来上游 refactor 行号可能偏移;函数名与逻辑相对稳定。**

---

## 十二、CFST 与 ProxyIP 的关系

### 12.1 常见误解澄清

网上很多教程把「CFST 优选」和「ProxyIP」混为一谈,实际是**完全不同的两条链路**上的东西。

| 概念 | 用途 | IP 类型 | 工具 |
|---|---|---|---|
| **CFST 优选 IP** | 客户端 → CF 边缘的**入口** | CF 自家 anycast(`104.16.x.x`/`172.67.x.x` 等) | XIU2/CloudflareSpeedTest |
| **ProxyIP** | Worker → CF 后端的**出口** | 反代 CF 的**第三方** IP(阿里云/BWG/甲骨文暴露的反代机) | fofa 扫、cmliussss 池、自建 |

### 12.2 为什么 CFST 结果直接当 ProxyIP 会失败

CFST 优选的目标是 CF 官方 IP 段(`https://www.cloudflare.com/ips-v4`)。这些 IP 用作 ProxyIP 时:

```
Worker connect(104.16.0.1:443)   ← 拨号到 CF 自家 IP
       ↓
CF 出站策略:REJECT               ← Worker → CF IP 段被官方封锁
       ↓
Error: Network error
```

所以 CFST 挑出来的 IP **对客户端加速有效,对 Worker 出站无效**。edgetunnel 的 `PROXYIP` 变量填这类 IP,访问 CF 站点时依然连不通[[6]](https://github.com/zizifn/edgetunnel/issues/162)。

### 12.3 CFST 的正确用途

CFST 优选结果应该填给**客户端的节点 URL 里的 `address` 字段**(如 vless://uuid@**这里**:443/...),不是 Worker 的 `PROXYIP` 环境变量。二者互不干扰。

### 12.4 什么样的 IP 才能当 ProxyIP

具备**同时满足**下面两条的 IP:

1. **反代了 CF 443 端口**:上面跑 nginx stream / iptables NAT / gost / haproxy 等 SNI 转发,把 443 流量原样转给 CF 官方 IP
2. **不在 CF 官方 IP 段内**:属于阿里云/BWG/甲骨文/家宽/自建 VPS 等**第三方**网段

来源多为:
- 疏于配置暴露到公网的企业/云服务器反代(fofa 可扫)
- 志愿者自建的 iptables NAT / gost / nginx stream(cmliussss 池)
- IPv6-only VPS 用 `ip6tables` 转发(cmliu 主推方案,不易被扫)

### 12.5 CFST 变体:AutoCloudflareSpeedTest2HAProxy

cmliu 的 [AutoCloudflareSpeedTest2HAProxy](https://github.com/cmliu/AutoCloudflareSpeedTest2HAProxy) 是把 CFST 优选结果**塞进 HAProxy 配置**,让你的 VPS 自动跟随最优 CF IP 更新反代目标。**这里 CFST 是"帮 HAProxy 选后端"**,不是"选 ProxyIP" —— 别混淆。

---

## 十三、稳定获取方案对比

| # | 方案 | 免费度 | 稳定性 | 部署难度 | 维护成本 |
|---|---|---|---|---|---|
| 1 | 公开域名池 `proxyip.cmliussss.net` | 全免费 | 高(209 IP,208 可用) | 零 | 零 |
| 2 | ymyuuu IPDB API `ipdb.api.030101.xyz/?type=bestproxy` | 全免费 | 中-高(30 分钟更新) | 零 | 零 |
| 3 | IPv6 iptables 自建(cmliu 脚本) | 需 IPv6 VPS(可白嫖) | 极高(自控) | 低 | 低 |
| 4 | IPv4 VPS iptables/gost/nginx SNI | 需 VPS | 高(易被扫到滥用) | 中 | 中 |
| 5 | GitHub Actions 定时扫描 + DNS 分发 | 全免费(public repo 无限额) | 高 | 中-高 | 中 |
| 6 | Cloudflare Worker 自建检测 + KV | 全免费 | 高 | 中 | 低 |
| 7 | 本项目 `proxyip-curator` + gist | 全免费(需机器跑) | 高 | 中 | 低 |
| 8 | nat64 兜底(yonggekkk 方案) | 全免费 | 中 | 低 | 零 |
| 9 | DNS TXT 池(CMLiussss 系列子域) | 全免费 | 高 | 零 | 零 |
| 10 | fofa 手动扫 + 检测器 | fofa 免费额度 2000/月 | 低(IP 流失快) | 低 | 高 |

### 13.1 公开池维护方对照

| 提供方 | URL | 更新频率 | 说明 |
|---|---|---|---|
| CMLiussss | `proxyip.cmliussss.net`(A) / `.us/sg/jp/kr/hk.cmliussss.net` | 12h/次 | TG @CMLiussss_channel 维护 |
| ymyuuu | `https://ipdb.api.030101.xyz/?type=bestproxy&country=true` | 30 分钟 | 2.5k stars,已 14.4 万次自动 commit |
| bihai | `https://raw.githubusercontent.com/hello-earth/cloudflare-better-ip/main/cf` | 每日 | 多协议输出 |
| zip.cm.edu.kg | `https://zip.cm.edu.kg/all.json` | 每日 | edgetunnel admin 默认源 |
| cmliu CheckProxyIP | `https://check.proxyip.cmliussss.net/check?proxyip=x.x.x.x` | 按需 API | 单 IP 检测服务 |

### 13.2 IPv6 自建为什么优于 IPv4

cmliu 明确说明[[2]](https://blog.cmliussss.com/p/iptableNewProxyIP/):

> IPv4 做反代 100% 会被扫出来被滥用,所以只写 IPv6 的教程。

**IPv6 优势**:地址空间大(2^128 vs 2^32),扫描器扫不到,自建后可长期专用。

一键脚本:
```bash
bash <(curl -Ls https://raw.cmliussss.com/ProxyIPv6.sh)
```

**免费 IPv6-only VPS 来源**:hostuno (free tier)、Serv00、EuroServ 部分套餐。

---

## 十四、推荐 Top 5 方案

按**稳定性 × 免费度 × 维护成本**综合排序,针对不同用户场景。

### D.1 完全懒人:公开域名池(推荐 90% 用户)

**一句话**:直接用别人维护好的池,`PROXYIP=proxyip.cmliussss.net` 收工。

```bash
wrangler secret put PROXYIP
# 输入:proxyip.cmliussss.net           (全球)
# 或:  proxyip.us.cmliussss.net        (美国)
# 或:  proxyip.jp.cmliussss.net        (日本)
```

- **服务**:cmliu 频道免费维护(12h/次,209 IP,208 可用)
- **步骤**:1 步
- **稳定性**:★★★★★
- **隐藏成本**:依赖第三方存续;集中使用可能被限流

### D.2 稳定 + 自动化:GitHub Actions + IPDB API(推荐给爱折腾但不想租 VPS)

**一句话**:GitHub Actions 每 6 小时从 `ipdb.api.030101.xyz` 拉最优 IP,通过 CF API 写回 worker 环境变量。

**基础 workflow**(`.github/workflows/refresh-proxyip.yml`):

```yaml
name: refresh-proxyip
on:
  schedule: [{cron: '17 */6 * * *'}]
  workflow_dispatch:
jobs:
  refresh:
    runs-on: ubuntu-latest
    steps:
      - name: fetch & push
        env:
          CF_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
          CF_ACCOUNT_ID: ${{ secrets.CF_ACCOUNT_ID }}
          CF_WORKER_NAME: ${{ secrets.CF_WORKER_NAME }}
        run: |
          BEST=$(curl -s 'https://ipdb.api.030101.xyz/?type=bestproxy&country=true' | head -30 | jq -R -s -c 'split("\n")|map(select(length>0))|join(",")')
          curl -sS -X PATCH \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$CF_WORKER_NAME/settings" \
            -d "{\"bindings\":[{\"type\":\"secret_text\",\"name\":\"PROXYIP\",\"text\":$BEST}]}"
```

- **服务**:GitHub Actions(public repo 无限额度)+ Cloudflare API(免费)+ ymyuuu 数据源
- **步骤**:配 3 个 secrets → push workflow
- **稳定性**:★★★★★(数据源 30 分钟更新)
- **隐藏成本**:CF API Token 权限管理

### D.3 完全自主 + 永久免费:IPv6 VPS 自建(推荐给长期用户)

**一句话**:白嫖一台 IPv6-only 廉价 VPS 跑 `ProxyIPv6.sh`,自建域名解析到 VPS 就是私有 ProxyIP。

```bash
# 1. 到 hostuno/Serv00/EuroServ 申请免费 IPv6-only VPS
# 2. SSH 进去执行
bash <(curl -Ls https://raw.cmliussss.com/ProxyIPv6.sh)
# 3. Cloudflare DNS 加 AAAA 记录 proxyip.你的域名 → VPS IPv6
# 4. Worker 配置
wrangler secret put PROXYIP
# 输入:[proxyip.你的域名]:443
```

- **服务**:IPv6 VPS(部分免费)+ Cloudflare DNS(免费)
- **步骤**:4 步
- **稳定性**:★★★★★(自控,IPv6 无扫描滥用)
- **隐藏成本**:VPS 保活;流量按自己用量;VPS 商禁流量放大攻击(正常使用不触及)

### D.4 中大规模多用户:LeilaoMi/cf-proxyip-us 全栈

**一句话**:fork [LeilaoMi/cf-proxyip-us](https://github.com/LeilaoMi/cf-proxyip-us),得到"稳定主 IP + failover + HMAC 分发 + ASN 分散"整套架构。

- **服务**:GitHub Actions + Cloudflare Worker + KV + DNS
- **步骤**:fork → 改 `wrangler.toml` → 配 `CLOUDFLARE_API_TOKEN` + `PROXYIP_HMAC_SECRET` → run workflow
- **稳定性**:★★★★★(每 3h 探测,cooldown 6h,连续失败才切换)
- **隐藏成本**:CF Worker CPU 免费额度 10 万请求/天;调试成本较高

### D.5 本项目 `proxyip-curator`(推荐给有闲置设备的用户)

**一句话**:本 repo 提供的 Alpine + shell docker 镜像,复测 + 拉源 + 探测 + 上传 gist 定时循环。

```bash
docker run -d --name proxyip-curator --restart=unless-stopped \
  -e GIST_TOKEN=ghp_xxx -e GIST_ID=abc123 \
  -e SOURCES="https://zip.cm.edu.kg/all.json,https://ipdb.api.030101.xyz/?type=bestproxy" \
  -e REGION_FILTER=JP,HK,SG \
  -e MAX_KEEP=100 -e INTERVAL_SEC=21600 \
  ghcr.io/harvey/proxyip-curator:latest
```

worker 侧:`PROXYIP=https://gist.githubusercontent.com/.../raw/proxyip.json` **不行**(worker 不主动拉 URL);正确做法是把 gist 内容通过前述 Actions 方案定期写回 worker env。

- **服务**:任意能跑 docker 的机器(NAS / 树莓派 / VPS)+ gist(免费)
- **步骤**:见 `proxyip-curator/README.md`
- **稳定性**:★★★★(依赖机器保活)
- **隐藏成本**:机器电费;gist 有 API rate limit(几 K 次/小时,循环 6h 一次远够)

### 场景选型

| 用户场景 | 推荐方案 |
|---|---|
| 我只想它能用 | D.1 |
| 我有 GitHub + CF 账号 | D.2 |
| 我有闲置 VPS 或想白嫖 IPv6 VPS | D.3 |
| 我在做多用户服务 | D.4 |
| 我有 NAS / 树莓派 | D.5 |
| 我想深度学习 CF 反代 | D.3 + D.4 组合 |

---

## 十五、FOFA 等测绘平台挖掘

> ⚠️ 本节仅作技术描述,使用他人未加固反代的法律风险见 § 十六。

### 15.1 六大平台对比

| 平台 | 归属 | 免费额度 | 语法风格 | 国内 IP | 特点 |
|---|---|---|---|---|---|
| **FOFA** | 华顺信安 | 2000 条/月导出,单条件 ≤ 10000 | `key=="value"` `&&` `\|\|` | 完整 | 中文首选,语法最全 |
| **Shodan** | Shodan LLC | 100 条 | `key:value` | 完整 | 海外首选,学生 `.edu` 邮箱白嫖 |
| **ZoomEye** | 知道创宇 | 月配额,黑五 lifetime $149 | `key:"value"` | 完整 | 官方 CLI `zoomeye-python` |
| **Censys** | Censys Inc. | 250 次/月 | Lucene 风格 | 完整 | **CT log 独家索引** |
| **Quake** | 360 CERT | 500 长期积分 | 类 FOFA | **前三段脱敏** | 数据源独立 |
| **Hunter** | 奇安信 | 100 F 点/月 | `key="value"` | 完整 | 与 FOFA 互补 |
| **crt.sh** | Sectigo | 完全免费 | SQL like | N/A | CT log 辅助 |

### 15.2 FOFA 核心查询模板

```
# 基础模板:CF 边缘特征 + 排除 CF 自身
server=="cloudflare" && asn!="13335" && asn!="209242"

# 甲骨文日本(实测最高命中率)
server=="cloudflare" && header="Forbidden" && asn!="13335" && asn!="209242" \
  && country=="JP" && port="443" && asn=="31898"

# Hetzner 芬兰 CN2 优选
server=="cloudflare" && port="443" && banner="HTTP/1.1 400 Bad Request" \
  && org="Hetzner Online GmbH" && country="FI"

# 香港任意运营商
port=="443" && header="Forbidden" && region=="HK"

# 阿里云兜底(IP 池巨大,质量参差)
server=="cloudflare" && asn=="45102"
```

### 15.3 关键 ASN 速查

| ASN | 归属 | 常见地区 | 备注 |
|---|---|---|---|
| **13335** | Cloudflare 自身 | 全球 | **必排除** `asn!="13335"` |
| **209242** | Cloudflare London | UK | **必排除** `asn!="209242"` |
| **31898** | Oracle Cloud(甲骨文) | KR/JP | ~14000 条,留存 1-4 周,稳定 |
| **45102** | 阿里云 Aliyun | CN/HK | 6万+ IP,SNI 转发居多 |
| **25820** | IT7 Networks(搬瓦工) | US-CN2 | ~100 条,443 留存高 |
| **24940** | Hetzner Online | DE/FI | 欧洲首选,ProxyIP-GET 默认 |
| **20473** | Vultr | 全球 | |
| **14061** | DigitalOcean | 全球 | |
| **16509** | AWS | 全球 | 命中率低,AWS 客户强 |
| **15169** | Google Cloud | 全球 | |

### 15.4 扩展语法

```
# 端口(CF 支持的 HTTPS 端口)
port=="443" / port=="2053" / port=="2083" / port=="2087" / port=="2096" / port=="8443"

# banner/header 判定伪反代
header="Forbidden"                    # nginx 空回落 403
banner="HTTP/1.1 400 Bad Request"     # HTTPS 端口收 HTTP 请求特征
header="cf-ray"                       # 强命中,反代成功回源
header="1003 Direct IP access not allowed"

# TLS 证书
cert.subject="cloudflare"
cert.issuer="Cloudflare Inc ECC CA-3"

# 布尔筛选
is_cloud=true          # 只看云厂商
is_domain=false        # 只要裸 IP
is_ipv6=false          # 排除 IPv6

# 时间切片(绕免费用户 10000 条上限)
after="2026-01-01" && before="2026-06-30"
```

### 15.5 开源工具选型

| 项目 | 语言 | 用途 |
|---|---|---|
| [Hurt-In-Dream/ProxyIP-GET](https://github.com/Hurt-In-Dream/ProxyIP-GET) | Python | **ProxyIP 专用**:FOFA→双验证→CF DNS 一条龙 |
| [FofaInfo/GoFOFA](https://github.com/FofaInfo/GoFOFA) | Go | 官方 CLI,支持 CSV 导出 |
| [xiecat/fofax](https://github.com/xiecat/fofax) | Go | 联动 nuclei,Fx 扩展语法 |
| [wgpsec/fofa_viewer](https://github.com/wgpsec/fofa_viewer) | JavaFX | 桌面 GUI,时间切片突破上限 |
| [atdpa4sw0rd/Search-Tools](https://github.com/atdpa4sw0rd/Search-Tools) | Python | 六平台聚合 |
| [EzXxY/CF-IP](https://github.com/EzXxY/CF-IP) | Python+masscan | 主动扫 CF ASN 段 |
| [luuaiyan/CloudflareProxyIP](https://github.com/luuaiyan/CloudflareProxyIP) | 数据仓库 | 现成 ProxyIP 池,免扫 |
| [cmliu/CF-Workers-CheckProxyIP](https://github.com/cmliu/CF-Workers-CheckProxyIP) | JS | Worker 端 ProxyIP 检测器 |

### 15.6 端到端 Pipeline

```
[FOFA 查询] → CSV → 去重 → TCP 443 探测 (masscan/naabu)
     ↓
[CF 特征验证] → TLS ClientHello + SNI=你的CF域名
     ↓
     HTTP GET /  → 400 / 1003 / cf-ray = 命中
     ↓
[CFST 测速] → 延迟 + 带宽
     ↓
[部署] → CF DNS A/AAAA / edgetunnel PROXYIP / 客户端节点
```

### 15.7 IP 生命周期(经验值)

- **输入**:2000 条 FOFA 原始 IP
- **验证通过**:5-15%(100-300 IP)
- **长期可用**:1-3%(20-60 IP)

| 来源 | 平均可用期 |
|---|---|
| 阿里云 / 搬瓦工 | 3-14 天 |
| 甲骨文 KR/JP | 1-4 周 |
| Hetzner FI | 不稳定,易被业主修复 |

### 15.8 与自建方案成本对比

| 方案 | 一次性 | 月固定 | 稳定性 | 法律风险 |
|---|---|---|---|---|
| **FOFA 扫别人反代** | 0(免费额度) | 0 | ★☆☆☆☆(3-14d 更换) | **高**,见 § 十六 |
| FOFA + F 点付费 | 300 元/1万 F 点 | ~50 元 | ★☆☆☆☆ | 高 |
| **自建 Hetzner** | 0 | €4.5(~35 元) | ★★★★★ | 无 |
| **自建甲骨文 always-free** | 0 | 0 | ★★★★ | 无 |
| **CF Argo Smart Routing** | 0 | $5+ | ★★★★★ | 无 |

---

## 十六、法律与道德边界

> **本节冷静客观陈述法律面。不给"如何规避""如何绕过"的路径。**

### 16.1 测绘平台数据本身

FOFA/Shodan 等**只公开互联网上"响应端口 banner"这类被动可观测数据**,一般视为"公开信息收集",与主动漏洞利用有本质区别。数据本身的**获取**通常合法。

### 16.2 使用他人反代的风险

将扫出的**他人未加固反代**当自家 CDN 前置或代理链路:

**中国大陆**:
- 《刑法》285 条(非法侵入计算机信息系统罪)/ 286 条(破坏计算机信息系统罪)通常需"侵入""破坏"要件。仅"利用 SNI 转发"是否构成需**个案判断**
- 《网络安全法》27 条禁止"提供专门用于从事侵入网络……的程序、工具"和"为他人从事……提供技术支持……的帮助"
- **将他人服务器当代理链路,若被认定为"未经授权使用他人计算资源",可构成民事侵权(不当得利/财产侵权),流量/电费损失可主张赔偿;情节严重可能触及刑事**

**美国**:
- **CFAA(18 U.S.C. § 1030)** "未授权访问 unauthorized access" 范围经 2021 *Van Buren v. United States* 案后收窄,但**"绕过技术屏障使用他人计算资源"仍属高危区**
- 若反代服务器 SNI 白名单机制存在但被绕过,更易被认定 unauthorized

**其他**:
- 欧盟 GDPR 关注个人数据,一般不直接触发
- 德国 StGB § 202a、英国 CMA 1990 等成员国立法均有类似 CFAA 的条款

### 16.3 业主发现后的可能后果

- **被动**:业主加 SNI 白名单 / 关闭 stream 转发 / iptables 限速 → 你的 ProxyIP 失效
- **主动**:
  - 提交 abuse 报告给你的 VPS 商 → **你的 worker 节点被封**
  - 提交 abuse 报告给 Cloudflare → **目标域名被扫黑**
  - 民事诉讼(极少但存在)
  - 报警(个案)

### 16.4 合规替代

- **自建**:第三方 VPS(Hetzner / Vultr / 甲骨文 always-free)自己跑 nginx stream + SNI 白名单,只允许自己域名。**零风险**
- **征得业主授权的公开池**:如 CMLiussss 系列自建池 —— 但**来源多混合**,不构成完整合规基础
- **CF Enterprise + Argo Tunnel**:官方付费方案,彻底绕开 ProxyIP 需求

### 16.5 建议

- **仅个人使用 + 短期测试**:风险低但仍存在
- **对外服务 / 商业使用**:必须自建,不可依赖扫出的第三方反代
- **本项目 `proxyip-curator`**:仅用于**你自己拥有或授权**的 IP 池的健康监测,不作为大规模 FOFA 扫描的自动化工具

---

## 十七、参考链接

1. [Cloudflare Workers TCP Sockets 官方文档](https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/) — 出站封锁官方声明
2. [cmliu IPv6 iptables 自建教程](https://blog.cmliussss.com/p/iptableNewProxyIP/)
3. [yydnas 获取 ProxyIP 三种方法](https://www.yydnas.cn/2025/10/06/2025.10.06-获取Cloudflare%20Workers%20ProxyIP的几种方法/)
4. [upsangel ProxyIP 原理研究](https://upsangel.com/security/vpn/cloudflare-worker-vless翻墙代理原理-proxyip细节研究/)
5. [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
6. [zizifn/edgetunnel issue #162 — proxyip 原理澄清](https://github.com/zizifn/edgetunnel/issues/162)
7. [bulianglin fofa 反代 IP 教程](https://bulianglin.com/archives/newcdn.html)
8. [ymyuuu/IPDB](https://github.com/ymyuuu/IPDB) — 2.5k stars 反代 IP 库
9. [cmliu/CF-Workers-CheckProxyIP](https://github.com/cmliu/CF-Workers-CheckProxyIP)
10. [yonggekkk/Cloudflare-vless-trojan](https://github.com/yonggekkk/Cloudflare-vless-trojan) — nat64 方案
11. [Zoroaaa/cf-bestip](https://github.com/Zoroaaa/cf-bestip) — Actions 定时扫描
12. [LeilaoMi/cf-proxyip-us](https://github.com/LeilaoMi/cf-proxyip-us) — DNS-only failover 全栈
13. [KafeMars/best-ips-domains](https://github.com/KafeMars/best-ips-domains)
14. [Yohann0617/scan-proxyip](https://github.com/Yohann0617/scan-proxyip) — docker `yohannfan/yohann-proxyip`
15. [cmliu/AutoCloudflareSpeedTest2HAProxy](https://github.com/cmliu/AutoCloudflareSpeedTest2HAProxy)
16. [CMLiussss TG 频道](https://t.me/CMLiussss_channel/39)
17. [CheckProxyIP Web 检测工具](https://check.proxyip.cmliussss.net/)
18. [CloudFlare 中国大陆地区优选方案汇总](https://blog.cmliussss.com/p/CloudFlare优选/)

### FOFA / 测绘

19. [FOFA 官方](https://fofa.info/) / [VIP 说明](https://fofa.info/vip)
20. [Shodan filters](https://www.shodan.io/search/filters)
21. [Censys CT 索引](https://docs.censys.com/docs/ls-certificates)
22. [ZoomEye pricing](https://www.zoomeye.ai/pricing)
23. [bulianglin newcdn 教程](https://bulianglin.com/archives/newcdn.html)
24. [Lyricn Wiki FOFA IP 搜索](https://wiki.lyricn.com/VPS/fofa/)
25. [yydnas 全手动 ProxyIP](https://www.yydnas.cn/2025/10/24/2025.10.24-%E5%85%A8%E6%89%8B%E5%8A%A8%E8%8E%B7%E5%8F%96%E7%8B%AC%E4%B8%80%E6%97%A0%E4%BA%8C%E7%9A%84Cloudflare%E4%B8%AD%E8%BD%AC%E5%8F%8D%E4%BB%A3IP-ProxyIP/)
26. [Hurt-In-Dream/ProxyIP-GET](https://github.com/Hurt-In-Dream/ProxyIP-GET)
27. [FofaInfo/GoFOFA](https://github.com/FofaInfo/GoFOFA)
28. [xiecat/fofax](https://github.com/xiecat/fofax)
29. [wgpsec/fofa_viewer](https://github.com/wgpsec/fofa_viewer)
30. [luuaiyan/CloudflareProxyIP 池](https://github.com/luuaiyan/CloudflareProxyIP)

### 法规

31. [中华人民共和国网络安全法(中)](https://www.cac.gov.cn/2016-11/07/c_1119867116.htm)
32. [Cybersecurity Law Stanford 英文译本](https://digichina.stanford.edu/work/translation-cybersecurity-law-of-the-peoples-republic-of-china-effective-june-1-2017/)
33. [CFAA 概览(维基)](https://en.wikipedia.org/wiki/Computer_Fraud_and_Abuse_Act)
