import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const REFERENCE='cc230413184bea9344a28efb8b1b1350d88e90e6952d180f67438ba78289d641';
export const CANDIDATE='ab82f9198e140dca19dee9d11915a20fe1c3a48224ecb0e8f9c91f7698a1d2b9';
export const SIGNER='0a0cfd297a4180aed3f1695cf6e2d697bee1d38444e4614b29a83143fca42d1b';
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');

export function restore({run,verify,backup,downloads,referenceHash=REFERENCE,signer=SIGNER}) {
    const root=fs.realpathSync(downloads), dir=fs.realpathSync(backup);
    if(path.dirname(dir)!==root || !path.basename(dir).startsWith('totti-readiness-backup-')) throw Error('復旧対象フォルダが不正です。端末未変更。');
    const record=JSON.parse(fs.readFileSync(path.join(dir,'backup.json'),'utf8'));
    const original=path.join(dir,'base.apk');
    if(record.package!=='com.helm.rode' || record.sha256!==referenceHash || hash(original)!==referenceHash || verify(original)!==signer)
        throw Error('復旧APKの照合失敗。端末未変更。');
    const current=run(['devices','-l']).split(/\r?\n/).some(x=>x.startsWith(record.serial+'\tdevice') || x.startsWith(record.serial+' device'));
    if(!current) throw Error('バックアップ時と同じ眼鏡が接続されていません。端末未変更。');
    const output=run(['-s',record.serial,'install','-r',original]);
    if(!/^Success\s*$/m.test(output)) throw Error('復旧成功を確認できません。状態未確定。');
    const paths=run(['-s',record.serial,'shell','pm','path','com.helm.rode']).split(/\r?\n/).filter(x=>x.startsWith('package:')).map(x=>x.slice(8).trim());
    if(paths.length!==1 || !/^\/data\/app\/[^\r\n]+\.apk$/.test(paths[0]) || paths[0].includes('..')) throw Error('復旧後のパス確認失敗。状態未確定。');
    const check=path.join(dir,'restored-check-'+crypto.randomUUID()+'.apk');
    run(['-s',record.serial,'pull',paths[0],check]);
    if(hash(check)!==referenceHash) throw Error('復旧後の実ファイル照合失敗。状態未確定。');
    return {restored:true,bytesVerified:true,deviceBehaviorVerified:false};
}

export function update({run,verify,sign,downloads,candidate,apply=false,referenceHash=REFERENCE,candidateHash=CANDIDATE,signer=SIGNER}) {
    if (hash(candidate)!==candidateHash) throw Error('候補APKが検証済みファイルと一致しません。端末未変更。');
    const devices=run(['devices','-l']).split(/\r?\n/).filter(x=>/^\S+\s+device(?:\s|$)/.test(x)).map(x=>x.split(/\s+/)[0]);
    const found=[];
    for (const serial of devices) {
        const paths=run(['-s',serial,'shell','pm','path','com.helm.rode'],true).split(/\r?\n/).filter(x=>x.startsWith('package:')).map(x=>x.slice(8).trim());
        if(paths.length) found.push({serial,paths});
    }
    if(found.length!==1) throw Error('TOTTIを持つ接続端末を1台に限定してください。端末未変更。');
    const {serial,paths}=found[0];
    if(paths.length!==1 || !/^\/data\/app\/[^\r\n]+\.apk$/.test(paths[0]) || paths[0].includes('..'))
        throw Error('split APKまたは想定外の構成です。端末未変更。');
    const dir=fs.mkdtempSync(path.join(downloads,'totti-readiness-backup-'));
    const original=path.join(dir,'base.apk');
    run(['-s',serial,'pull',paths[0],original]);
    const backupHash=hash(original);
    fs.writeFileSync(path.join(dir,'backup.json'),JSON.stringify({serial,package:'com.helm.rode',sha256:backupHash,restoreTested:false},null,2),{flag:'wx'});
    if(backupHash!==referenceHash) throw Error('現行APKが照合済み10/19版と異なります。上書きせず保存しました：'+dir);
    if(verify(original)!==signer) throw Error('現行APKの署名不一致。端末未変更。');
    const signed=path.join(dir,'readiness-signed.apk');
    sign(candidate,signed,signer);
    if(verify(signed)!==signer) throw Error('再署名の照合失敗。端末未変更。');
    if(!apply) return {prepared:true,installed:false,backup:dir};
    // All reads, baseline identity checks, and local signing complete before this single mutation.
    const result=run(['-s',serial,'install','-r',signed]);
    if(!/^Success\s*$/m.test(result)) throw Error('ADBが更新成功を返しませんでした。状態未確定。バックアップ：'+dir);
    // Verify installed bytes, not just adb's success string. Do not change settings or auto-start audio.
    const installedPaths=run(['-s',serial,'shell','pm','path','com.helm.rode']).split(/\r?\n/).filter(x=>x.startsWith('package:')).map(x=>x.slice(8).trim());
    if(installedPaths.length!==1 || !/^\/data\/app\/[^\r\n]+\.apk$/.test(installedPaths[0]) || installedPaths[0].includes('..'))
        throw Error('更新後APKパスを確認できません。更新済みの可能性あり。バックアップ：'+dir);
    const check=path.join(dir,'installed-check.apk');
    run(['-s',serial,'pull',installedPaths[0],check]);
    if(hash(check)!==hash(signed)) throw Error('更新後APK照合失敗。更新済みの可能性あり。バックアップ：'+dir);
    return {prepared:true,installed:true,bytesVerified:true,backup:dir,deviceBehaviorVerified:false};
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
    const root=path.dirname(fileURLToPath(import.meta.url));
    const profile=process.env.USERPROFILE;
    const adb='C:\\Android\\Sdk\\platform-tools\\adb.exe';
    const exec=(file,args,allow=false)=>{
        const r=spawnSync(file,args,{encoding:'utf8',shell:false,timeout:120000,maxBuffer:8*1024*1024});
        if(r.error || (r.status!==0&&!allow)) throw Error('実行を停止しました：'+path.basename(file)+' / '+(r.error?.code??'終了コード'+r.status));
        return r.status===0 ? (r.stdout??'') : '';
    };
    try {
        if(!profile || !fs.existsSync(adb)) throw Error('Windowsの既存ADB環境が見つかりません。端末未変更。');
        const javaChoices=['java',process.env.JAVA_HOME&&path.join(process.env.JAVA_HOME,'bin','java.exe'),
            path.join(process.env.ProgramFiles||'C:\\Program Files','Android','Android Studio','jbr','bin','java.exe')].filter(Boolean);
        const javaExe=javaChoices.find(executable=>{
            const probe=spawnSync(executable,['--version'],{encoding:'utf8',shell:false,timeout:15000});
            return probe.status===0 && Number((probe.stdout||'').match(/(?:openjdk|java)\s+(\d+)/)?.[1])>=17;
        });
        if(!javaExe) throw Error('既存のJava17以上が見つかりません。インストールや端末変更は行っていません。');
        const key=path.join(profile,'.android','debug.keystore');
        const java=args=>exec(javaExe,['--class-path',path.join(root,'apksig-8.6.1.jar'),path.join(root,'ApkGuard.java'),...args]).trim();
        const restoreIndex=process.argv.indexOf('--restore');
        if(restoreIndex!==-1) {
            const result=restore({run:(args,allow)=>exec(adb,args,allow),verify:p=>java(['verify',p]),
                backup:process.argv[restoreIndex+1],downloads:path.join(profile,'Downloads')});
            console.log(JSON.stringify(result,null,2));process.exit(0);
        }
        if(!fs.existsSync(key)) throw Error('既存のAndroid署名鍵がありません。新しい鍵は作りません。端末未変更。');
        const result=update({run:(args,allow)=>exec(adb,args,allow),verify:p=>java(['verify',p]),
            sign:(input,output,cert)=>java(['sign',input,output,key,cert]),downloads:path.join(profile,'Downloads'),
            candidate:path.join(root,'readiness-candidate.apk'),apply:process.argv.includes('--apply')});
        console.log(JSON.stringify(result,null,2));
        console.log(result.installed?'更新ファイル照合完了。音声・HUDの実機動作は未確認です。':'署名・準備確認のみ完了。端末未変更。');
    } catch(e) {console.error('停止：'+e.message);process.exitCode=1;}
}
