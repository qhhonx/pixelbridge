import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const catalogs = Object.fromEntries(['en','zh-Hans'].map(language => [language, JSON.parse(fs.readFileSync(`locales/${language}.json`, 'utf8'))]));
assert.deepEqual(Object.keys(catalogs.en).sort(), Object.keys(catalogs['zh-Hans']).sort());
for (const [language, copy] of Object.entries(catalogs)) {
  for (const [key, value] of Object.entries(copy)) {
    assert.match(key, /^[a-z][a-z0-9_]*$/);
    assert.ok(value.trim(), `${language}: ${key}`);
    assert.ok(!value.includes('Mac mini'), `${language}: personal device copy`);
  }
}
const js = ts.transpileModule(fs.readFileSync('lib/i18n.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
const context = { exports: {}, require: path => catalogs[path.includes('zh-Hans') ? 'zh-Hans' : 'en'] };
vm.runInNewContext(js, context);
const { resolveLanguage, acceptedLanguages } = context.exports;
assert.equal(resolveLanguage('system', ['zh-TW','en']), 'zh-Hans');
assert.equal(resolveLanguage('system', ['fr-FR','zh-CN']), 'en');
assert.equal(resolveLanguage('en', ['zh-CN']), 'en');
assert.equal(resolveLanguage('zh-Hans', ['en-US']), 'zh-Hans');
assert.equal(resolveLanguage('invalid', []), 'en');
assert.equal(resolveLanguage('system', acceptedLanguages('en;q=0.5,zh-CN;q=0.9')), 'zh-Hans');
assert.equal(resolveLanguage('system', acceptedLanguages('zh;q=0,en;q=1')), 'en');
console.log(`PASS: ${Object.keys(catalogs.en).length} semantic keys; locale fallback, explicit selection and Accept-Language priority`);
if (process.env.I18N_TEST_URL) {
  for (const [label, headers, language, title] of [
    ['English locale', {'accept-language':'en-US'}, 'en', catalogs.en.hero_title_first],
    ['Chinese locale', {'accept-language':'zh-CN'}, 'zh-Hans', catalogs['zh-Hans'].hero_title_first],
    ['Explicit English', {'accept-language':'zh-CN', cookie:'pixelbridge-language=en'}, 'en', catalogs.en.hero_title_first],
    ['Explicit Chinese', {'accept-language':'en-US', cookie:'pixelbridge-language=zh-Hans'}, 'zh-Hans', catalogs['zh-Hans'].hero_title_first],
  ]) {
    const response = await fetch(process.env.I18N_TEST_URL, { headers });
    assert.equal(response.status, 200, label);
    const body = await response.text();
    assert.ok(body.includes(`lang="${language}"`), label);
    assert.ok(body.includes(title), label);
    assert.ok(body.includes(catalogs[language].faq_progress_question), label);
    console.log(`PASS: ${label}, localized server document and content`);
  }
}
