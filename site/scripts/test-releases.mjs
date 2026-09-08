import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const js=ts.transpileModule(fs.readFileSync('lib/releases.ts','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText;
const context={exports:{},require:()=>({}),process:{env:{}},URL};
vm.runInNewContext(js,context);
const {completeRelease}=context.exports;
function release(tag,date){
 const names=[`PixelBridge-${tag.slice(1)}-arm64.zip`,'appcast.xml','SHA256SUMS'];
 return {draft:false,tag_name:tag,published_at:date,assets:names.map(name=>({name,size:100,browser_download_url:`https://github.com/qhhonx/pixelbridge/releases/download/${tag}/${name}`}))};
}
const first=release('v0.1.0-beta.1','2026-01-01T00:00:00Z');
const next=release('v0.1.0-beta.2','2026-01-02T00:00:00Z');
assert.equal(completeRelease([]),null);
assert.equal(completeRelease([first,next]).tag,next.tag_name);
assert.equal(completeRelease([{...first,published_at:'2027-01-01T00:00:00Z'},next]).tag,next.tag_name);
assert.equal(completeRelease([first,{...next,draft:true}]).tag,first.tag_name);
assert.equal(completeRelease([first,{...next,assets:next.assets.slice(0,2)}]).tag,first.tag_name);
assert.equal(completeRelease([first,{...next,assets:next.assets.map(a=>({...a,browser_download_url:'https://example.invalid/'+a.name}))}]).tag,first.tag_name);
assert.equal(completeRelease([first,{...next,assets:next.assets.map(a=>({...a,size:0}))}]).tag,first.tag_name);
assert.equal(completeRelease([{...next,tag_name:'v9-experimental'}]),null);
console.log('PASS: beta ordering, draft/incomplete/empty/wrong-origin exclusion and no-release fallback');
