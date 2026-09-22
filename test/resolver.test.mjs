import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const R = path.resolve('lib/js-resolver.mjs');

function run(code, fragment) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'r-'));
  const f = path.join(dir, 'b.js');
  fs.writeFileSync(f, code);
  try {
    const out = execFileSync('node', [R, f, fragment], { encoding: 'utf8', stdio: ['ignore','pipe','ignore'] });
    return out.trim().split('\n').filter(Boolean).sort();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ۱. الگوی مستقیم
test('direct object', () => {
  assert.deepEqual(
    run(`fetch("/x", {body: JSON.stringify({a:1,b:2})});`, '/x'),
    ['a','b']
  );
});

// ۲. wrapper سفارشی — چیزی که همه ابزارهای دیگه رد میکنن
test('custom wrapper', () => {
  assert.deepEqual(
    run(`Qb("POST", "/x", {name:1, email:2});`, '/x'),
    ['email','name']
  );
});

// ۳. تابع محلی
test('local function', () => {
  assert.deepEqual(
    run(`function build(f){return {title:f.t, priority:f.p};}
         fetch("/x", {body: JSON.stringify(build(y))});`, '/x'),
    ['priority','title']
  );
});

// ۴. spread
test('spread', () => {
  assert.deepEqual(
    run(`const base={a:1,b:2}; fetch("/x", {body: JSON.stringify({...base, c:3})});`, '/x'),
    ['a','b','c']
  );
});

// ۵. boundary — مهمترین تست
test('does not match subpath', () => {
  const src = `Qb("POST", "/api/v1/my-projects/generate", {name:1, db:2});`;
  assert.deepEqual(run(src, '/api/v1/my-projects'), []);     // ← باید خالی
  assert.deepEqual(run(src, '/api/v1/my-projects/generate'), ['db','name']);
});

// ۶. route map رد بشه
test('route map is rejected', () => {
  const src = `const r={a:"/api/a",b:"/api/b",c:"/api/c"};`;
  assert.deepEqual(run(src, '/api/b'), []);
});