import { describe, it, expect, vi } from 'vitest';
import crypto from 'crypto';
import worker from './_worker.js';

// Polyfill Web Crypto API for Node.js environment
if (!globalThis.crypto) {
  globalThis.crypto = {
    subtle: {
      digest: async (algorithm, data) => {
        const hash = crypto.createHash(algorithm.toLowerCase().replace('-', ''));
        hash.update(Buffer.from(data));
        return hash.digest();
      }
    }
  };
} else if (!globalThis.crypto.subtle) {
    globalThis.crypto.subtle = {
      digest: async (algorithm, data) => {
        const hash = crypto.createHash(algorithm.toLowerCase().replace('-', ''));
        hash.update(Buffer.from(data));
        return hash.digest();
      }
    };
} else {
    const originalDigest = globalThis.crypto.subtle.digest;
    globalThis.crypto.subtle.digest = async (algorithm, data) => {
        if (algorithm === 'MD5') {
            const hash = crypto.createHash('md5');
            hash.update(Buffer.from(data));
            return hash.digest();
        }
        return originalDigest(algorithm, data);
    };
}


describe('Worker', () => {
  it('should export a fetch function', () => {
    expect(typeof worker.fetch).toBe('function');
  });

  it('should respond with html on base route (default camo)', async () => {
    const env = {
      UUID: '12345678-1234-4234-8234-123456789012'
    };

    const request = new Request('https://example.com/');
    Object.defineProperty(request, 'cf', {
      value: { colo: 'SJC' },
      writable: true,
      configurable: true
    });

    const ctx = {
      waitUntil: vi.fn(),
    };

    const response = await worker.fetch(request, env, ctx);
    expect(response).toBeDefined();
    expect(response.status).toBe(200);
    // Returns default Nginx page or similar camouflage
    expect(response.headers.get('content-type')).toContain('text/html');
  });
});

describe('Worker config parsing', () => {
    it('should parse hosts correctly without throwing', async () => {
        const env = {
            HOST: 'example.com, test.com:443, https://another.com'
        };
        const request = new Request('https://example.com/');
        Object.defineProperty(request, 'cf', {
          value: { colo: 'SJC' },
          writable: true,
          configurable: true
        });
        const ctx = {
            waitUntil: vi.fn(),
        };
        const response = await worker.fetch(request, env, ctx);
        // Either 200 or 404 is fine as long as we successfully parse the HOST array and don't throw an error in string manipulations.
        // It's 404 here because with custom HOST, the worker might not find a matching proxy route or camouflage route internally.
        expect([200, 404, 302, 301]).toContain(response.status);
    });
});
