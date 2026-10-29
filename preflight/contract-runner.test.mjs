import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
test('runner validates sources, flags, and compiler/executable failure propagation',()=>{
 const temp=fs.mkdtempSync(path.join(root,'build-runner-test-'));
 const bin=path.join(temp,'bin');fs.mkdirSync(bin);
 const compiler=`#!/usr/bin/env node
const fs=require('node:fs');const a=process.argv.slice(2);
for(const p of a.filter(x=>x.endsWith('.swift')))if(!fs.existsSync(p))process.exit(51);
fs.appendFileSync(process.env.TEST_CALLS,JSON.stringify(a)+'\\n');
if(process.env.TEST_FAIL==='compile')process.exit(52);
const out=a[a.indexOf('-o')+1];
fs.writeFileSync(out,'#!/bin/sh\\nexit '+(process.env.TEST_FAIL==='execute'?'53':'0')+'\\n',{mode:0o700});
`;
 fs.writeFileSync(path.join(bin,'swiftc'),compiler,{mode:0o700});
 function run(variant,fail=''){
  const calls=path.join(temp,variant+'-'+(fail||'ok')+'.jsonl');
  const r=spawnSync('bash',['preflight/run-contracts.sh'],{cwd:root,encoding:'utf8',env:{...process.env,PATH:bin+path.delimiter+process.env.PATH,AUDIO_VARIANT:variant,TEST_FAIL:fail,TEST_CALLS:calls}});
  return {...r,calls:fs.existsSync(calls)?fs.readFileSync(calls,'utf8').trim().split('\n').map(JSON.parse):[]};
 }
 for(const variant of ['legacy','duplex']){
  const r=run(variant);assert.equal(r.status,0,r.stderr);assert.equal(r.calls.length,6);
  for(const args of r.calls){assert(args.includes('TOTTI_CONTRACT_TEST'));assert.equal(args.includes('TOTTI_EXPERIMENTAL_DUPLEX'),variant==='duplex');}
  assert.equal((r.stdout.match(/PASS contract executable/g)||[]).length,6);
 }
 assert.equal(run('invalid').status,2);
 const compile=run('legacy','compile');assert.equal(compile.status,52);assert.equal(compile.calls.length,1);assert(!compile.stdout.includes('PASS'));
 const execute=run('duplex','execute');assert.equal(execute.status,53);assert.equal(execute.calls.length,1);assert(!execute.stdout.includes('PASS'));
});
