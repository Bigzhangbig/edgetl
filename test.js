import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripIPv6Brackets } from './_worker.js';

test('stripIPv6Brackets extracts IPv6 from brackets', () => {
    assert.equal(stripIPv6Brackets('[2001:db8::1]'), '2001:db8::1');
});

test('stripIPv6Brackets handles regular IPs and hostnames without changes', () => {
    assert.equal(stripIPv6Brackets('192.168.1.1'), '192.168.1.1');
    assert.equal(stripIPv6Brackets('example.com'), 'example.com');
});

test('stripIPv6Brackets handles edge cases', () => {
    assert.equal(stripIPv6Brackets('[2001:db8::1'), '[2001:db8::1');
    assert.equal(stripIPv6Brackets('2001:db8::1]'), '2001:db8::1]');
});

test('stripIPv6Brackets handles empty and null inputs', () => {
    assert.equal(stripIPv6Brackets(''), '');
    assert.equal(stripIPv6Brackets(null), '');
    assert.equal(stripIPv6Brackets(undefined), '');
});

test('stripIPv6Brackets trims whitespace before stripping brackets', () => {
    assert.equal(stripIPv6Brackets('   [2001:db8::1]   '), '2001:db8::1');
});
