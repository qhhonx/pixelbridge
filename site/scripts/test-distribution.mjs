import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function route(path, enabled) {
  let lookups = 0;
  const source = ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const context = { exports: {}, URL, Response, AbortSignal, require: name => name.includes('distribution')
    ? { publicReleasesEnabled: enabled }
    : { latestRelease: async () => { lookups++; return null; }, releasesURL: 'https://github.com/example/product/releases' } };
  vm.runInNewContext(source, context);
  return { get: context.exports.GET, lookups: () => lookups };
}
const download = route('app/download/route.ts', false);
const result = await download.get(new Request('https://product.example/download'));
assert.equal(result.status, 307);
assert.equal(result.headers.get('location'), 'https://product.example/#download');
assert.equal(download.lookups(), 0, 'Private-release mode must not query GitHub');
const feed = route('app/appcast.xml/route.ts', false);
const unavailable = await feed.get();
assert.equal(unavailable.status, 503);
assert.equal(unavailable.headers.get('cache-control'), 'no-store');
assert.equal(feed.lookups(), 0);
const publicDownload = route('app/download/route.ts', true);
const fallback = await publicDownload.get(new Request('https://product.example/download'));
assert.equal(fallback.headers.get('location'), 'https://github.com/example/product/releases');
assert.equal(publicDownload.lookups(), 1);
console.log('PASS: private-stage routes avoid GitHub access and private links; public-mode fallback remains available');
