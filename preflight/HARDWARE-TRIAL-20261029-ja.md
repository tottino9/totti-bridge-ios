# 最新：割り込み会話の実機試験引継ぎ — 2026-10-29 JST

本記録はRESULT-20261029-ja.mdの「未パッケージ化」の段階を更新する。実機導入成功は未確認。

## 確定した試験版
- ソースcommit: 7dc5f0cc9453ba47667bd72e8661428746de221b
- CI: https://github.com/tottino9/totti-bridge-ios/actions/runs/40826788555 (両job/build/回帰/包装成功)
- 元artifact: totti-test-duplex-resignable / 12876838160
- artifact ZIP SHA256: 1c42f5d60188f59480019cba2f2215e3e2480ff8f7ad4482c07d18e642c6759d
- IPA: Totti-barge-test-20261029-build1029.ipa
- IPA SHA256: 766a8296f8ad3ff48b3f53d0bfde4acf9e2a1a71e423d77b52e8be654c44f472
- IPA size: 5860544
- 永続成果物: libfile_2c342236944c81919cf1b5d8794b8cb5
- CFBundleIdentifier com.anezium.rokidlyrics / CFBundleVersion 1029 / variant duplex
- arm64 iOS16+ / SDK18.5 / cryptid0 / 実行体にTottiDuplexAudioあり
- RGCxrClient UUIDは正常版と同じ1467c23a-c190-315e-b332-3fab78a9e4f4
- 元IPAからのリネームのみでハッシュ不変。
- Apple CI codesign --verify --deep --strictで valid on disk / satisfies its Designated Requirement を確認。ただしad-hoc署名であり、iPhoneへのインストールには所有者によるSideloadly再署名が必要。
- ローカルverify-ipa.pyでZIP CRC・manifestサイズ/ハッシュ/commit・bundle/build/variant・MachO/SDKを確認。正常版との入替、誤hash、誤size、誤commitの4拒否試験も通過。
- LinuxでApple codesignを実行したという意味ではない。

## 復旧基準
既存正常版IPA SHA256 e84cf545bc2f1b9ce941327566e14b80163878f00f226e7f8899b60ca4e347d8 を再照合。
既存成果物libfile_ca3138846e9c81918945f73cbd1df265。再ビルドlegacy版は復旧用として代用しない。
本日、利用不可からSideloadly更新・信頼設定・通常会話への復旧を利用者が報告。
ただし今回candidate1029導入後→正常版build1への復元は未実施。署名アカウント/アプリ識別子が同じ条件でのみ上書きを行い、削除や識別子変更を要求されたら停止。
端末設定の完全バックアップを助手が取得したとは扱わない。

## 所有者へ依頼する一度のセッション
iPhone USB接続・ロック解除、Sideloadlyで試験IPAを前回と同じApple ID/詳細設定のまま上書き署名・導入。認証だけ本人が行う。削除しない。
Done後、アプリ前面、眼鏡装着、3tap。
1. 短い通常会話を1往復。
2. 「日本の都道府県を全部教えて」の読み上げ途中で「2足す3は？」と言う。再生停止と新発話の回答を確認。
3. 次の読み上げを遮らず聞き、無言で少し待つ。自己TTSを拾って勝手に回答を始めないか確認。
4. バイバイ→ROKID AI→3tap→短い通常会話。
最初の通常会話が失敗したら後続試験はしない。正常版IPAを同じ方法で上書きして復帰。削除しない。
署名と物理操作を除き、追加の開発コマンド/ログの手動読み出しは依頼しない。
実機の回答だけでは遅延やエコー抑制の定量合格を付けない。まず可否と失敗点を収集する。

## 今回混ぜていない変更
Android APK、黒丸の状態表示同期、本番Worker、記憶/履歴/資料、Bluetooth設定。
iOS実入力readyの通知は候補に存在するが、Android表示の独立同期修正が導入済みとは言わない。
現行APKのハッシュ照合は未完了。今回はそのAPKを一切交換しないiOS単独の試験。
実HFP/AEC、入力再開、ロック/スリープ/切断、長時間安定、今回の復元実行は未確認。
試験IPAができた段階を日常利用の完成とはしない。
チャット後の自動継続は設定していない。再開時は本記録を読む。

