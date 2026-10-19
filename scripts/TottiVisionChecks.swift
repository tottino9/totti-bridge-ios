import Foundation

@main
struct VisionChecks {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        for text in ["これ何？", "これは何？", "写真を撮って説明して", "目の前のものを説明して", "見えている文字を読んで", "何が見える？"] {
            check(TottiVisionPolicy.requestsCapture(text), "Capture request missed: " + text)
        }
        for text in ["こんにちは", "クレアの名前を覚えて", "写真を撮らないで", "写真撮影しないで", "これ何？撮影しないで", "写真の撮り方を教えて", "昨日の写真は何枚あった？", "記憶を削除して"] {
            check(!TottiVisionPolicy.requestsCapture(text), "Unrequested camera use: " + text)
        }
        let jpeg = Data([0xff,0xd8,0xff,0xe0,0,0,0xff,0xd9])
        let encoded = try TottiVisionPolicy.imageDataURL(jpeg)
        check(encoded == "data:image/jpeg;base64," + jpeg.base64EncodedString(), "Image encoding mismatch")
        for invalid in [Data(), Data("<svg>bad</svg>".utf8), Data([0xff,0xd8,0xff,0]), Data(repeating:0,count:TottiVisionPolicy.maxJPEGBytes+1)] {
            do { _ = try TottiVisionPolicy.imageDataURL(invalid); fatalError("Invalid image accepted") }
            catch TottiVisionPolicy.Failure.invalidImage { }
        }
        let integration = TottiIntegration(baseURL:"https://test.example", token:String(repeating:"a",count:64), sessionID:"vision_test", mode:"chat")
        let request = try integration.visionRequest(text:"これ何？",jpeg:jpeg)
        let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        check(request.url?.absoluteString == "https://test.example/api/chat", "Wrong endpoint")
        check(request.allowsCellularAccess, "Cellular disabled")
        check(body["mode"] as? String == "vision", "Vision mode missing")
        check(body["session_id"] as? String == "vision_test", "History ID changed")
        check(body["image"] as? String == "data:image/jpeg;base64,"+jpeg.base64EncodedString(), "Image not in request")
        let regular = try integration.chatRequest(text:"こんにちは")
        let regularBody = try JSONSerialization.jsonObject(with:regular.httpBody!) as! [String:Any]
        check(regularBody["image"] == nil && regularBody["mode"] as? String == "chat", "Normal chat changed")
        let response = try JSONSerialization.data(withJSONObject:["answer":"青い箱です。","session_id":"vision_test","history_saved":true,"revision":1])
        let decoded = try integration.decode(response,status:200)
        check(decoded.text == "青い箱です。", "Existing reply decoder incompatible")
        print("PASS: capture intent, opt-out, invalid data, image request, cellular, history and normal-chat contracts")
    }
}
