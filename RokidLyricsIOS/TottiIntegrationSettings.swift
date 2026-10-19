import SwiftUI

struct TottiIntegrationSettings: View {
    @State private var enabled = UserDefaults.standard.bool(forKey: "totti.integration.enabled")
    @State private var url = UserDefaults.standard.string(forKey: "totti.integration.url") ?? "https://throbbing-dew-e798totti-ai-memory-test.toshiakino-9.workers.dev"
    @State private var history = UserDefaults.standard.string(forKey: "totti.integration.history") ?? ""
    @State private var mode = UserDefaults.standard.string(forKey: "totti.integration.mode") ?? "chat"
    @State private var token = ""
    @State private var status = UserDefaults.standard.string(forKey: "totti.integration.lastResult") ?? ""
    var body: some View {
        GroupBox("トッティ：履歴・記憶の統合") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("PC側の履歴・記憶を利用", isOn: $enabled)
                Text("初期状態はOFF。保存後の次の会話から適用します。会話中の変更は避けてください。バイバイで終了しても履歴IDは保持します。")
                TextField("PC用WorkerのHTTPSルートURL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("メニュートークン（空欄なら保存済みを使用）", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("履歴ID（空欄なら新規生成）", text: $history).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("モード", selection: $mode) {
                    Text("通常会話").tag("chat")
                    Text("資料を参照").tag("rag")
                    Text("Web検索").tag("web")
                }
                Button("設定を保存") {
                    do {
                        try TottiIntegrationStore.save(enabled: enabled, url: url.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines), history: history.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode)
                        token = ""
                        history = UserDefaults.standard.string(forKey: "totti.integration.history") ?? ""
                        status = "設定を保存しました。API接続の成功確認はまだです。"
                    } catch { status = error.localizedDescription }
                }
                Button("新しい履歴IDを用意") { history = UUID().uuidString; status = "保存すると次の会話から新しい履歴になります。" }
                Button("統合を停止してトークンを削除") {
                    do {
                        try TottiIntegrationStore.keychain.delete(account: "menu-token")
                        UserDefaults.standard.set(false, forKey: "totti.integration.enabled")
                        enabled = false; token = ""; status = "統合を停止しました。PC側の履歴・記憶は保持しています。"
                    } catch { status = error.localizedDescription }
                }
                Text(status).font(.footnote)
                Text("会話で覚えてと言うだけでは記憶を変更しません。追加・訂正・削除はPCメニューで行います。出典情報はiPhone内に保持します。") .font(.footnote)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundColor(.white)
        .tint(.green)
        .textFieldStyle(.roundedBorder)
    }
}
