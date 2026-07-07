import { describe, it } from 'node:test';
import assert from 'node:assert';
import { isSpeedTestSite } from './_worker.js';

describe('isSpeedTestSite', () => {
    it('should return true for exactly speed.cloudflare.com', () => {
        assert.strictEqual(isSpeedTestSite('speed.cloudflare.com'), true);
    });

    it('should return true for valid subdomains of speed.cloudflare.com', () => {
        assert.strictEqual(isSpeedTestSite('test.speed.cloudflare.com'), true);
        assert.strictEqual(isSpeedTestSite('a.b.c.speed.cloudflare.com'), true);
    });

    it('should return false for unrelated domains', () => {
        assert.strictEqual(isSpeedTestSite('example.com'), false);
        assert.strictEqual(isSpeedTestSite('cloudflare.com'), false);
    });

    it('should return false for domains that just contain the string but are not subdomains', () => {
        assert.strictEqual(isSpeedTestSite('myspeed.cloudflare.com.example.com'), false);
        assert.strictEqual(isSpeedTestSite('notspeed.cloudflare.com'), false);
    });

    it('should return false for empty strings', () => {
        assert.strictEqual(isSpeedTestSite(''), false);
    });

    it('should throw TypeError for null or undefined input', () => {
        assert.throws(() => isSpeedTestSite(undefined), TypeError);
        assert.throws(() => isSpeedTestSite(null), TypeError);
    });
});
