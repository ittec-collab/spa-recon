#!/usr/bin/env node
// lib/js-resolver.mjs — AST-based request body field resolver
//
// Detects HTTP calls by PATTERN, not by function name. Handles
// minified custom wrappers like Qb("POST", url, body).
//
// URL matching is boundary-aware: "/api/v1/my-projects" will not
// match "/api/v1/my-projects/generate".
//
// Identifier resolution is scope-aware: a parameter of the enclosing
// function is never resolved against top-level bindings.
//
// IMPORTANT: NODE_PATH does not work for ESM imports in Node. We
// therefore resolve @babel/core and @babel/parser via createRequire()
// with explicit candidate paths.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// ============================================================
// locate @babel/core and @babel/parser
//
// Search order:
//   1. $SPA_RECON_NODE_MODULES  (explicit override)
//   2. <script-dir>/../node/node_modules    (installed layout)
//   3. <script-dir>/node_modules            (self-contained layout)
//   4. <script-dir>/../node_modules         (shared layout)
//   5. plain require from the script itself (global fallback)
// ============================================================
function locateBabel() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [];

  if (process.env.SPA_RECON_NODE_MODULES) {
    candidates.push(process.env.SPA_RECON_NODE_MODULES);
  }
  candidates.push(
    path.join(here, '..', 'node', 'node_modules'),
    path.join(here, 'node_modules'),
    path.join(here, '..', 'node_modules'),
  );

  for (const dir of candidates) {
    const pkg = path.join(dir, '@babel', 'core', 'package.json');
    if (fs.existsSync(pkg)) {
      const req = createRequire(path.join(dir, 'noop.js'));
      return {
        traverse: req('@babel/core').traverse,
        parse:    req('@babel/parser').parse,
        dir,
      };
    }
  }

  // last resort — let Node resolve from the script's own location
  const req = createRequire(import.meta.url);
  return {
    traverse: req('@babel/core').traverse,
    parse:    req('@babel/parser').parse,
    dir: '<global>',
  };
}

let babel;
try {
  babel = locateBabel();
} catch (e) {
  console.error('js-resolver: cannot load @babel/core —', e.message);
  console.error('');
  console.error('install the runtime deps:');
  console.error('  cd ~/.local/share/spa-recon/node && npm install @babel/core @babel/parser');
  console.error('');
  console.error('or point at an existing node_modules:');
  console.error('  SPA_RECON_NODE_MODULES=/path/to/node_modules ' + process.argv[1] + ' ...');
  process.exit(1);
}

const traverse = babel.traverse;
const parse    = babel.parse;

// ============================================================
// args
// ============================================================
const [file, urlFragment] = process.argv.slice(2);
if (!file || !urlFragment) {
  console.error('usage: js-resolver.mjs <js-file> <url-fragment>');
  process.exit(1);
}

let source;
try {
  source = fs.readFileSync(file, 'utf8');
} catch (e) {
  console.error('read failed:', e.message);
  process.exit(1);
}

let ast;
try {
  ast = parse(source, {
    sourceType: 'unambiguous',
    plugins: ['jsx', 'typescript', 'classProperties', 'objectRestSpread'],
    errorRecovery: true,
  });
} catch (e) {
  console.error('parse failed:', e.message);
  process.exit(1);
}

// ============================================================
// binding map — name → initializer node
// ============================================================
const bindings = new Map();

traverse(ast, {
  VariableDeclarator(p) {
    if (p.node.id.type === 'Identifier' && p.node.init) {
      if (!bindings.has(p.node.id.name))
        bindings.set(p.node.id.name, p.node.init);
    }
  },
  FunctionDeclaration(p) {
    if (p.node.id && !bindings.has(p.node.id.name))
      bindings.set(p.node.id.name, p.node);
  },
  ArrowFunctionExpression(p) {
    const parent = p.parent;
    if (parent.type === 'VariableDeclarator' && parent.id.type === 'Identifier') {
      if (!bindings.has(parent.id.name))
        bindings.set(parent.id.name, p.node);
    }
  },
});

// ============================================================
// URL matching — boundary-aware
//
// A fragment F matches a URL string S when F appears in S and the
// character after the match is one of:
//   • end-of-string         (exact endpoint)
//   • ? # &                 (query / fragment)
//   • placeholder U+0001    (template literal `${...}`)
//   • / followed by end, /, or placeholder
// Anything else (letter, digit, dash) means a longer path segment,
// so the match is rejected.
// ============================================================
const PLACEHOLDER = '\u0001';

function literalMatches(value, fragment) {
  if (typeof value !== 'string') return false;

  let idx = value.indexOf(fragment);
  while (idx !== -1) {
    const afterIdx = idx + fragment.length;
    const after = value[afterIdx];

    if (after === undefined) return true;
    if (after === '?' || after === '#' || after === '&') return true;
    if (after === PLACEHOLDER) return true;

    if (after === '/') {
      const next = value[afterIdx + 1];
      if (next === undefined) return true;
      if (next === '/' || next === PLACEHOLDER) return true;
      idx = value.indexOf(fragment, idx + 1);
      continue;
    }

    idx = value.indexOf(fragment, idx + 1);
  }
  return false;
}

function templateMatches(node, fragment) {
  const raw = node.quasis.map(q => q.value.cooked).join(PLACEHOLDER);
  return literalMatches(raw, fragment);
}

function nodeContainsFragment(node, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 20) return false;
  if (node.type === 'StringLiteral') return literalMatches(node.value, urlFragment);
  if (node.type === 'TemplateLiteral') return templateMatches(node, urlFragment);

  for (const key of Object.keys(node)) {
    if (['loc', 'start', 'end', 'leadingComments', 'trailingComments'].includes(key)) continue;
    const child = node[key];
    if (Array.isArray(child)) {
      if (child.some(c => nodeContainsFragment(c, depth + 1))) return true;
    } else if (child && typeof child === 'object' && child.type) {
      if (nodeContainsFragment(child, depth + 1)) return true;
    }
  }
  return false;
}

// ============================================================
// non-HTTP callee filter
// ============================================================
const NON_HTTP_CALLEE = new Set([
  'log', 'warn', 'error', 'info', 'debug', 'trace',
  'stringify', 'parse', 'test', 'match', 'exec',
  'assert', 'expect',
  'map', 'filter', 'reduce', 'forEach', 'find', 'some', 'every',
  'push', 'pop', 'shift', 'unshift', 'slice', 'splice', 'concat',
  'keys', 'values', 'entries', 'assign', 'freeze', 'seal',
  'encodeURIComponent', 'decodeURIComponent',
]);

function isNonHttpCallee(callee) {
  if (!callee) return false;
  if (callee.type === 'Identifier') return NON_HTTP_CALLEE.has(callee.name);
  if (callee.type === 'MemberExpression' && callee.property.type === 'Identifier') {
    return NON_HTTP_CALLEE.has(callee.property.name);
  }
  return false;
}

// ============================================================
// collect parameters of a function node
// ============================================================
function collectParams(fnNode) {
  const set = new Set();
  if (!fnNode || !fnNode.params) return set;

  for (const p of fnNode.params) {
    if (p.type === 'Identifier') {
      set.add(p.name);
    } else if (p.type === 'AssignmentPattern' && p.left.type === 'Identifier') {
      set.add(p.left.name);
    } else if (p.type === 'RestElement' && p.argument.type === 'Identifier') {
      set.add(p.argument.name);
    } else if (p.type === 'ObjectPattern') {
      for (const prop of p.properties || []) {
        if (prop.type === 'ObjectProperty' && prop.value.type === 'Identifier') {
          set.add(prop.value.name);
        }
      }
    }
  }
  return set;
}

// ============================================================
// candidate collection
// ============================================================
const candidates = [];

traverse(ast, {
  CallExpression(p) {
    const callee = p.node.callee;
    if (isNonHttpCallee(callee)) return;

    const args = p.node.arguments;
    if (args.length === 0) return;

    let urlIdx = -1;
    for (let i = 0; i < args.length; i++) {
      if (nodeContainsFragment(args[i])) { urlIdx = i; break; }
    }
    if (urlIdx === -1) return;

    // pick the body — first non-string argument after the URL
    let bodyNode = null;
    for (let i = urlIdx + 1; i < args.length; i++) {
      const a = args[i];
      if (a.type === 'StringLiteral') continue;
      if (a.type === 'ObjectExpression' ||
          a.type === 'Identifier' ||
          a.type === 'CallExpression' ||
          a.type === 'MemberExpression') {
        bodyNode = a;
        break;
      }
    }
    if (!bodyNode) return;

    // if the picked node is an options object with body/data, unwrap one level
    if (bodyNode.type === 'ObjectExpression') {
      for (const prop of bodyNode.properties) {
        if (prop.type === 'ObjectProperty' &&
            prop.key.type === 'Identifier' &&
            (prop.key.name === 'body' || prop.key.name === 'data')) {
          bodyNode = prop.value;
          break;
        }
      }
    }

    // record parameters of the enclosing function so unwrap can
    // refuse to resolve them against top-level bindings
    const fnPath = p.getFunctionParent();
    const params = fnPath ? collectParams(fnPath.node) : new Set();

    candidates.push({ body: bodyNode, params });
  },
});

// ============================================================
// unwrap — chase identifiers back to their initializers
// ============================================================
function unwrap(node, params, depth = 0) {
  if (!node || depth > 10) return null;

  // JSON.stringify(x) → x
  if (node.type === 'CallExpression' &&
      node.callee.type === 'MemberExpression' &&
      node.callee.object.type === 'Identifier' &&
      node.callee.object.name === 'JSON' &&
      node.callee.property.name === 'stringify') {
    return unwrap(node.arguments[0], params, depth + 1);
  }

  if (node.type === 'ObjectExpression') return node;

  if (node.type === 'Identifier') {
    // never resolve a function parameter against top-level bindings —
    // minifiers reuse short names across scopes
    if (params.has(node.name)) return null;
    const bound = bindings.get(node.name);
    return bound ? unwrap(bound, params, depth + 1) : null;
  }

  if (node.type === 'CallExpression' && node.callee.type === 'Identifier') {
    if (params.has(node.callee.name)) return null;
    const fn = bindings.get(node.callee.name);
    return fn ? unwrap(fn, params, depth + 1) : null;
  }

  if (['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type)) {
    const innerParams = new Set([...params, ...collectParams(node)]);
    if (node.body.type === 'ObjectExpression') return node.body;
    if (node.body.type === 'BlockStatement') {
      for (const stmt of node.body.body) {
        if (stmt.type === 'ReturnStatement') {
          const r = unwrap(stmt.argument, innerParams, depth + 1);
          if (r) return r;
        }
      }
    }
  }

  return null;
}

// ============================================================
// collect keys from an ObjectExpression
// ============================================================
function collectKeys(objNode, out, params, depth = 0) {
  if (!objNode || depth > 4) return out;
  if (objNode.type !== 'ObjectExpression') return out;

  for (const prop of objNode.properties) {
    if (prop.type === 'ObjectProperty') {
      if (prop.key.type === 'Identifier') out.add(prop.key.name);
      else if (prop.key.type === 'StringLiteral') out.add(prop.key.value);
    } else if (prop.type === 'SpreadElement') {
      collectKeys(unwrap(prop.argument, params), out, params, depth + 1);
    }
  }
  return out;
}

// ============================================================
// output
// ============================================================
const all = new Set();
for (const { body, params } of candidates) {
  const r = unwrap(body, params);
  if (r) collectKeys(r, all, params);
}

for (const k of [...all].sort()) console.log(k);