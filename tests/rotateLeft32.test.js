import assert from 'node:assert';
import test from 'node:test';
import { rotateLeft32 } from '../_worker.js';

test('rotateLeft32 - Bitwise rotation functionality', async (t) => {
    await t.test('basic rotation - rotate 1 left by 1 bit', () => {
        assert.strictEqual(rotateLeft32(1, 1), 2);
    });

    await t.test('basic rotation - rotate 1 left by 31 bits', () => {
        assert.strictEqual(rotateLeft32(1, 31), 2147483648);
    });

    await t.test('edge case - rotate 0', () => {
        assert.strictEqual(rotateLeft32(0, 5), 0);
    });

    await t.test('edge case - rotate max 32-bit integer', () => {
        assert.strictEqual(rotateLeft32(0xFFFFFFFF, 1), 0xFFFFFFFF);
        assert.strictEqual(rotateLeft32(0xFFFFFFFF, 15), 0xFFFFFFFF);
    });

    await t.test('pattern rotation - rotating 0x0F0F0F0F by 4', () => {
        assert.strictEqual(rotateLeft32(0x0F0F0F0F, 4), 0xF0F0F0F0);
    });

    await t.test('pattern rotation - rotating 0x55555555 by 1', () => {
        assert.strictEqual(rotateLeft32(0x55555555, 1), 0xAAAAAAAA);
    });
});
