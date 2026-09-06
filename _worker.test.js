import test from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';

const code = fs.readFileSync('./_worker.js', 'utf8');
const funcCodeMatch = code.match(/function 读取十六进制半字节\(code\) \{[\s\S]*?return -1;\n\}/);

if (!funcCodeMatch) {
  throw new Error("Could not find function 读取十六进制半字节 in _worker.js");
}

const funcCode = funcCodeMatch[0];

const 读取十六进制半字节 = new Function(`
  ${funcCode}
  return 读取十六进制半字节;
`)();

test('读取十六进制半字节 (Hex Decoder Utility)', async (t) => {
  await t.test('decodes digits 0-9 (ASCII 48-57)', () => {
    for (let i = 0; i <= 9; i++) {
      assert.strictEqual(读取十六进制半字节(i + 48), i);
    }
  });

  await t.test('decodes lowercase a-f (ASCII 97-102)', () => {
    for (let i = 0; i < 6; i++) {
      assert.strictEqual(读取十六进制半字节(i + 97), i + 10);
    }
  });

  await t.test('decodes uppercase A-F (ASCII 65-70)', () => {
    for (let i = 0; i < 6; i++) {
      assert.strictEqual(读取十六进制半字节(i + 65), i + 10);
    }
  });

  await t.test('returns -1 for invalid characters', () => {
    const invalidChars = [
      47, // '/'
      58, // ':'
      64, // '@'
      71, // 'G'
      96, // '`'
      103, // 'g'
      0,
      255
    ];
    for (const code of invalidChars) {
      assert.strictEqual(读取十六进制半字节(code), -1, `Failed for ASCII ${code}`);
    }
  });
});
