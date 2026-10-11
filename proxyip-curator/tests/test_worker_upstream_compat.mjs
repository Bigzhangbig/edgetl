import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const workerPath = fileURLToPath(new URL('../../_worker.js', import.meta.url));
const workerSource = readFileSync(workerPath, 'utf8').replace('export default {', 'globalThis.__worker = {');
const UUID = '00000000-0000-4000-8000-000000000000';
const directURL = 'https://api.fixture.invalid/list.csv';
const generatorURL = `https://generator.fixture.invalid/sub?host=example.com&uuid=${UUID}`;
const directCSV = 'IP地址,端口,数据中心,国家,TLS\n198.51.100.12,443,HKG,HKG,true\n';
const generatorLines = [
  `vless://${UUID}@example.com:443?security=tls#Real`,
  `vless://${UUID}@notexample.com:443?security=tls#Keep`,
].join('\n');
const poolURL = 'https://pool.fixture.invalid/proxies.json';
const poolJSON = JSON.stringify([
  { proxy: '203.0.113.7:443#ignored', colo: 'hkg', egress: 'v4' },
  { proxy: '[2001:db8::7]:443', colo: 'HKG', egress: 'v4' },
  { proxy: '203.0.113.8:443', colo: 'sin', egress: 'v6' },
]);

function loadWorker(source = workerSource) {
  const calls = [];
  const fetch = async (input, options = {}) => {
    const url = String(input);
    calls.push({ url, options });
    if (url === directURL) return new Response(directCSV, { headers: { 'content-type': 'text/csv; charset=utf-8' } });
    if (url === generatorURL) return new Response(btoa(generatorLines));
    if (url === poolURL) return new Response(poolJSON);
    throw new Error(`unexpected external fetch: ${url}`);
  };
  const context = { Proxy, URL, TextDecoder, TextEncoder, AbortController, AbortSignal, Response, fetch, atob, btoa, setTimeout, clearTimeout, console };
  vm.runInNewContext(source, context, { filename: workerPath });
  return { context, calls };
}

function assertUA(call, uid) {
  assert.ok(call, 'expected fetch was not made');
  const ua = call.options.headers?.['User-Agent'];
  assert.match(ua, new RegExp(` Uid/0x${uid} Version/\\d{14}$`));
}

async function checkUpstreamCompatibility(source = workerSource) {
  const { context, calls } = loadWorker(source);
  const direct = await context.请求优选API([directURL], '443', '42');
  assert.deepEqual(Array.from(direct[0]), ['198.51.100.12:443#🇭🇰HK [HKG]']);
  assertUA(calls.find(call => call.url === directURL), '42');

  calls.length = 0;
  const defaultUid = await context.请求优选API([directURL]);
  assert.deepEqual(Array.from(defaultUid[0]), ['198.51.100.12:443#🇭🇰HK [HKG]']);
  assertUA(calls.find(call => call.url === directURL), '000000');

  calls.length = 0;
  const nested = await context.请求优选API(['sub://generator.fixture.invalid#Source'], '443', 'nested42');
  assert.deepEqual(Array.from(nested[0]), ['example.com:443#Real [Source]']);
  assert.deepEqual(Array.from(nested[1]), [`vless://${UUID}@notexample.com:443?security=tls#Keep%20%5BSource%5D`]);
  assertUA(calls.find(call => call.url === generatorURL), 'nested42');

  calls.length = 0;
  const generatorDefault = await context.获取优选订阅生成器数据('sub://generator.fixture.invalid');
  assert.deepEqual(Array.from(generatorDefault[0]), ['example.com:443#Real']);
  assertUA(calls.find(call => call.url === generatorURL), '000000');
}

async function checkForkHelpers() {
  const { context, calls } = loadWorker();
  const pool = await context.获取PROXYIP池('pool.fixture.invalid/proxies.json');
  assert.equal(calls[0]?.url, poolURL, 'path-like PROXYIP source should gain https://');
  assert.deepEqual(Array.from(pool, item => [item.proxy, item.colo, item.egress]), [
    ['203.0.113.7:443', 'HKG', 'v4'],
    ['[2001:db8::7]:443', 'HKG', 'v4'],
    ['203.0.113.8:443', 'SIN', 'v6'],
  ]);
  assert.deepEqual(Array.from(context.selectSafeProxyIPs(pool), item => item.proxy), ['203.0.113.7:443']);

  let reads = 0;
  const env = { KV: { get: async (key, type) => {
    reads++;
    assert.equal(key, 'config.json');
    assert.equal(type, 'json');
    return { 反代: { PROXYIP: ' 203.0.113.9:443 ' } };
  } } };
  assert.equal(await context.从KV读PROXYIP(env), '203.0.113.9:443');
  assert.equal(await context.从KV读PROXYIP(env), '203.0.113.9:443');
  assert.equal(reads, 1, 'KV result should be cached');
  assert.equal(context.格式化机场三字码地区('HKG / unknown'), '🇭🇰HK / unknown');
}

await checkUpstreamCompatibility();
await checkForkHelpers();

// Recreate each pre-merge signature in memory. The same real worker body then
// lacks the uid argument; the assertions above must reject that regression.
for (const [label, current, old] of [
  ['direct API uid', '请求优选API(urls, 默认端口 = \'443\', uid = "000000", 超时时间 = 3000)', '请求优选API(urls, 默认端口 = \'443\', 超时时间 = 3000)'],
  ['nested generator uid', '获取优选订阅生成器数据(优选订阅生成器HOST, uid = "000000")', '获取优选订阅生成器数据(优选订阅生成器HOST)'],
]) {
  assert.ok(workerSource.includes(current), `${label}: expected signature was not found`);
  const mutant = workerSource.replace(current, old);
  await assert.rejects(() => checkUpstreamCompatibility(mutant), error => error instanceof assert.AssertionError, `${label}: regression was not detected by a result assertion`);
}

console.log('PASS: worker upstream and fork compatibility (including two signature regressions)');
