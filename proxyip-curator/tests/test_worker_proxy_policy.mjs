import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../..', import.meta.url));
const workerPath = `${root}/_worker.js`;
const source = readFileSync(workerPath, 'utf8').replace('export default {', 'globalThis.__worker = {');
const context = {
  Proxy,
  URL,
  TextDecoder,
  TextEncoder,
  console,
};
vm.runInNewContext(source, context, { filename: workerPath });

const { isStrictIPv4Proxy, selectSafeProxyIPs, parseProxyAddressPort } = context;
if (typeof isStrictIPv4Proxy !== 'function' || typeof selectSafeProxyIPs !== 'function' || typeof parseProxyAddressPort !== 'function') {
  throw new Error('worker IPv4 proxy policy helpers are missing');
}

const pool = [
  { proxy: '[2001:db8::1]:443', egress: 'v4' },
  { proxy: '203.0.113.1:443', egress: 'v6' },
  { proxy: '203.0.113.2:443', egress: 'v4' },
];

if (!isStrictIPv4Proxy('203.0.113.1:443#US')) throw new Error('literal IPv4 should be accepted');
if (isStrictIPv4Proxy('[2001:db8::1]:443')) throw new Error('IPv6 must not pass strict IPv4 policy');
if (isStrictIPv4Proxy('203.0.113.999:443')) throw new Error('invalid IPv4 must not pass strict IPv4 policy');

const selected = selectSafeProxyIPs(pool).map(item => item.proxy);
if (selected.join(',') !== '203.0.113.2:443') {
  throw new Error(`trusted IPv4 candidates should win, got ${selected.join(',')}`);
}

const v4Fallback = selectSafeProxyIPs(pool.map(item => ({ ...item, egress: 'unknown' }))).map(item => item.proxy);
if (v4Fallback.join(',') !== '203.0.113.1:443,203.0.113.2:443') {
  throw new Error(`literal IPv4 fallback should exclude IPv6, got ${v4Fallback.join(',')}`);
}

if (selectSafeProxyIPs([{ proxy: '[2001:db8::2]:443', egress: 'v4' }]).length !== 0) {
  throw new Error('an IPv6-only pool must not be selected even with stale egress metadata');
}

const bracketed = parseProxyAddressPort('[2001:db8::3]:8443');
if (bracketed[0] !== '[2001:db8::3]' || bracketed[1] !== 8443) {
  throw new Error(`bracketed IPv6 port boundary is wrong: ${bracketed}`);
}
const rawIPv6 = parseProxyAddressPort('2001:db8::3');
if (rawIPv6[0] !== '2001:db8::3' || rawIPv6[1] !== 443) {
  throw new Error(`raw IPv6 default port is wrong: ${rawIPv6}`);
}
if (parseProxyAddressPort('[2001:db8::3]:99999')[1] !== 0) {
  throw new Error('out-of-range bracketed port must be rejected');
}

console.log('PASS: worker proxy policy');
