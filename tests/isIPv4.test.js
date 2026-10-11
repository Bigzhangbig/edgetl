const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert');

// Read _worker.js
const workerPath = path.join(__dirname, '..', '_worker.js');
const workerCode = fs.readFileSync(workerPath, 'utf-8');

// Extract the isIPv4 function using regex
const match = workerCode.match(/function isIPv4\(.*?\)\s*\{[\s\S]*?\n\}(?=\n*function|\n*$)/);
if (!match) {
	console.error("Could not find isIPv4 function in _worker.js");
	process.exit(1);
}

// Evaluate the function in a new VM context
const context = {};
vm.createContext(context);
vm.runInContext(match[0], context);
const isIPv4 = context.isIPv4;

console.log("Running tests for isIPv4...");

// Valid IPv4 addresses
assert.strictEqual(isIPv4('127.0.0.1'), true, 'Localhost IP should be valid');
assert.strictEqual(isIPv4('0.0.0.0'), true, 'All zeros IP should be valid');
assert.strictEqual(isIPv4('255.255.255.255'), true, 'Broadcast IP should be valid');
assert.strictEqual(isIPv4('192.168.1.1'), true, 'Private IP should be valid');
assert.strictEqual(isIPv4('10.0.0.1'), true, 'Private IP should be valid');
assert.strictEqual(isIPv4('172.16.254.1'), true, 'Private IP should be valid');
assert.strictEqual(isIPv4('8.8.8.8'), true, 'Public IP should be valid');
assert.strictEqual(isIPv4('08.08.08.08'), true, 'IP with leading zeros should be valid');

// Invalid IPv4 addresses - out of range
assert.strictEqual(isIPv4('256.0.0.0'), false, 'Part > 255 should be invalid');
assert.strictEqual(isIPv4('192.168.1.256'), false, 'Part > 255 should be invalid');
assert.strictEqual(isIPv4('-1.0.0.0'), false, 'Negative parts should be invalid');
assert.strictEqual(isIPv4('1.1.1.-1'), false, 'Negative parts should be invalid');
assert.strictEqual(isIPv4('1.1.1.999'), false, 'Part with > 3 digits should be invalid');

// Invalid IPv4 addresses - wrong number of parts
assert.strictEqual(isIPv4('127.0.0'), false, '3 parts should be invalid');
assert.strictEqual(isIPv4('127.0.0.1.1'), false, '5 parts should be invalid');
assert.strictEqual(isIPv4(''), false, 'Empty string should be invalid');
assert.strictEqual(isIPv4('192.168.1'), false, 'Incomplete IP should be invalid');

// Invalid IPv4 addresses - non-numeric parts
assert.strictEqual(isIPv4('a.b.c.d'), false, 'Letters should be invalid');
assert.strictEqual(isIPv4('192.168.1.a'), false, 'Alphanumeric mix should be invalid');
assert.strictEqual(isIPv4('192.168.1. '), false, 'Spaces should be invalid');
assert.strictEqual(isIPv4('192.168. 1.1'), false, 'Spaces in parts should be invalid');
assert.strictEqual(isIPv4(' 192.168.1.1 '), false, 'Leading/trailing spaces should be invalid');

// Invalid types
assert.strictEqual(isIPv4(null), false, 'null should be invalid');
assert.strictEqual(isIPv4(undefined), false, 'undefined should be invalid');
assert.strictEqual(isIPv4(123), false, 'numbers should be invalid');
assert.strictEqual(isIPv4({}), false, 'objects should be invalid');
assert.strictEqual(isIPv4([]), false, 'arrays should be invalid');

console.log("✅ All isIPv4 tests passed successfully!");
