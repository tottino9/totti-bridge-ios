import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {update,restore,REFERENCE,SIGNER} from './Update-TottiReadiness.mjs';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
function fixture(options={}){
 const downloads=fs.mkdtempSync(path.join(import.meta.dirname,'fixture-'));
 const candidate=path.join(downloads,'candidate.apk');fs.writeFileSync(candidate,'candidate');
 const calls=[];
 const run=args=>{
  calls.push(args);
  if(args[0]==='devices') return options.noDevice?'List of devices attached\n':'G1 device product:glasses\n';
  if(args.includes('pm')) return options.split?'package:/data/app/pkg/base.apk\npackage:/data/app/pkg/split.apk':'package:/data/app/pkg/base.apk';
  if(args.includes('pull')){fs.writeFileSync(args.at(-1),args.at(-1).endsWith('installed-check.apk')?(options.badPost?'bad':'signed'):(options.wrongBaseline?'wrong':'original'));return '';}
  if(args.includes('install')) return options.badInstall?'Failure [SIGNATURE]':'Success\n';
  throw Error('Unexpected '+args);
 };
 return {calls,args:{downloads,candidate,candidateHash:hash('candidate'),referenceHash:hash('original'),signer:'cert',run,
 verify:p=>options.badSignature?'other':'cert',
 sign:(input,output)=>{if(options.missingKey)throw Error('key mismatch');fs.writeFileSync(output,'signed');}}};
}
test('dry run signs only and never installs',()=>{const f=fixture();const r=update(f.args);assert.equal(r.installed,false);assert(!f.calls.some(x=>x.includes('install')));});
test('validated update installs once with -r and verifies actual bytes',()=>{const f=fixture();const r=update({...f.args,apply:true});assert.equal(r.bytesVerified,true);assert.equal(r.deviceBehaviorVerified,false);assert.equal(f.calls.filter(x=>x.includes('install')).length,1);assert(f.calls.find(x=>x.includes('install')).includes('-r'));});
for(const [name,options] of Object.entries({noDevice:{noDevice:true},split:{split:true},wrongBaseline:{wrongBaseline:true},badSignature:{badSignature:true},missingKey:{missingKey:true}})){
 test(name+' stops before any device mutation',()=>{const f=fixture(options);assert.throws(()=>update({...f.args,apply:true}));assert(!f.calls.some(x=>x.includes('install')||x.includes('uninstall')));});
}
test('modified candidate stops before ADB',()=>{const f=fixture();fs.appendFileSync(f.args.candidate,'tampered');assert.throws(()=>update({...f.args,apply:true}));assert.equal(f.calls.length,0);});
test('install failure is not reported as success',()=>{const f=fixture({badInstall:true});assert.throws(()=>update({...f.args,apply:true}),/状態未確定/);});
test('post-install byte mismatch is explicit and never triggers uninstall',()=>{const f=fixture({badPost:true});assert.throws(()=>update({...f.args,apply:true}),/更新済みの可能性/);assert(!f.calls.some(x=>x.includes('uninstall')));});

function restoreFixture(options={}) {
 const downloads=fs.mkdtempSync(path.join(import.meta.dirname,'restore-fixture-'));
 const backup=fs.mkdtempSync(path.join(downloads,'totti-readiness-backup-'));
 fs.writeFileSync(path.join(backup,'base.apk'),'original');
 fs.writeFileSync(path.join(backup,'backup.json'),JSON.stringify({serial:'G1',package:'com.helm.rode',sha256:hash('original')}));
 if(options.tampered) fs.appendFileSync(path.join(backup,'base.apk'),'x');
 const calls=[];
 const run=args=>{calls.push(args);
  if(args[0]==='devices')return options.wrongDevice?'G2 device':'G1 device';
  if(args.includes('install'))return 'Success';
  if(args.includes('pm'))return 'package:/data/app/pkg/base.apk';
  if(args.includes('pull')) {fs.writeFileSync(args.at(-1),options.badPost?'wrong':'original');return '';}
  throw Error('Unexpected command');
 };
 return {calls,args:{downloads,backup,run,verify:()=>SIGNER,referenceHash:hash('original')}};
}
test('restore preserves package data and verifies installed bytes',()=>{const f=restoreFixture();const r=restore(f.args);assert.equal(r.bytesVerified,true);assert.equal(r.deviceBehaviorVerified,false);assert(f.calls.find(x=>x.includes('install')).includes('-r'));assert(!f.calls.some(x=>x.includes('uninstall')));});
for(const [name,options] of Object.entries({tampered:{tampered:true},wrongDevice:{wrongDevice:true}})) test('restore '+name+' refuses mutation',()=>{const f=restoreFixture(options);assert.throws(()=>restore(f.args));assert(!f.calls.some(x=>x.includes('install')));});
test('restore detects wrong installed bytes',()=>{const f=restoreFixture({badPost:true});assert.throws(()=>restore(f.args),/実ファイル照合失敗/);});
