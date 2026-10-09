import Combine
import Foundation
import OSLog

#if !targetEnvironment(simulator)
    import RGCxrClient
#endif

@MainActor
final class LyricsCxrTransport: ObservableObject {
    @Published private(set) var status = DeviceStatus(
        connectionState: .connecting,
        statusLabel: "CXR-L waiting for Rokid app authentication."
    )

    var onMessage: ((GlassesToPhoneMessage) -> Void)?
    var onSubscribed: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var protocolReady = false
    private var subscriptionNotified = false
    private var didOpenCustomApp = false
    private var openLoopActive = false
    private var openAttempts = 0
    private let maxOpenAttempts = 3
    private var pendingMessages: [PendingMessage] = []
    private var flushRetryScheduled = false
    private let maxPendingMessages = 16
    private let maxSendAttempts = 3
    private let logger = Logger(subsystem: "app.nectarine4657.lime425", category: "CXR")

    private struct PendingMessage {
        var message: PhoneToGlassesMessage
        var priority: Bool
        var attempts: Int
    }

    #if !targetEnvironment(simulator)
        private var link: (any RGCxrLink)?
        private var session: (any RGCxrCustomAppSession)?
    #endif

    init() {
        #if targetEnvironment(simulator)
            status = DeviceStatus(
                connectionState: .disconnected,
                statusLabel: "CXR-L is available on iPhone builds only."
            )
        #else
            initializeClient()
            bindLegacyClientEvents()
        #endif
    }

    var isConnected: Bool {
        protocolReady
    }

    func authenticate() {
        #if targetEnvironment(simulator)
            status = DeviceStatus(
                connectionState: .disconnected,
                statusLabel: "Run on iPhone to authenticate CXR-L."
            )
        #else
            print("[RokidLyricsCXR] authenticate()")
            initializeClient()
            let link = self.link ?? CxrClient.makeLink(appDisplayName: "Rokid Lyrics")
            self.link = link
            bind(link)
            status = DeviceStatus(connectionState: .connecting, statusLabel: "Opening Rokid CXR-L authentication.")
            link.authenticate(scopes: [.media, .camera, .microphone]) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        print("[RokidLyricsCXR] auth success")
                        print("[RokidLyricsCXR] granted scopes \(CxrClient.shared.auth.grantedScopes)")
                        self?.configureCustomAppSession()
                    case let .failure(error):
                        print("[RokidLyricsCXR] auth failed \(error.localizedDescription)")
                        self?.status = DeviceStatus(
                            connectionState: .disconnected,
                            statusLabel: "CXR-L authentication failed: \(error.localizedDescription)",
                            lastError: error.localizedDescription
                        )
                    }
                }
            }
        #endif
    }

    func handleOpenURL(_ url: URL) -> Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            if link?.handleOpenURL(url) == true {
                return true
            }
            return CxrClient.shared.handleOpenURL(url)
        #endif
    }

    func send(_ message: PhoneToGlassesMessage, priority: Bool = false) {
        #if targetEnvironment(simulator)
            return
        #else
            guard protocolReady, didOpenCustomApp else {
                print("[RokidLyricsCXR] queued channelReady=false protocolReady=\(protocolReady) appOpen=\(didOpenCustomApp) \(safeSummary(message))")
                enqueue(PendingMessage(message: message, priority: priority, attempts: 0))
                return
            }
            sendNow(PendingMessage(message: message, priority: priority, attempts: 1))
        #endif
    }

    func dropQueuedWrites() {
        pendingMessages.removeAll()
    }

    #if !targetEnvironment(simulator)
        private func sendNow(_ pending: PendingMessage) {
            // The glasses app reads the custom-command payload as a Rokid Caps binary member, so
            // wrap the JSON in a proper Caps v5 blob. The SDK base64-transports the raw payload
            // bytes as-is; the glasses do Caps.fromBytes(payload).
            guard let json = try? WireProtocol.encodePhoneMessage(pending.message),
                  let jsonData = json.data(using: .utf8)
            else { return }
            let data = CxrCapsCodec.encodeBinaryPayload(jsonData)
            let summary = safeSummary(pending.message)
            print("[RokidLyricsCXR] send attempt=\(pending.attempts) \(summary) capsBytes=\(data.count)")
            logger.info("Sending CXR-L \(summary, privacy: .public) bytes=\(data.count)")
            let callback: (Bool, Data?, Int32?, String?) -> Void = { [weak self] success, _, errorCode, errorMessage in
                print("[RokidLyricsCXR] send callback success=\(success) code=\(errorCode ?? 0) message=\(errorMessage ?? "")")
                self?.logger.info("CXR-L send callback success=\(success) code=\(errorCode ?? 0) message=\(errorMessage ?? "")")
                guard !success else { return }
                // This SDK often reports callback success=false even for commands that the
                // glasses already received. Treat it as diagnostic only; immediate SDK errors
                // still drive retries below.
            }

            // Global custom-command send (correct for `.customApp` mode). NOTE: currently returns
            // notReady until the glasses custom app is confirmed open via the SDK — see
            // ensureCustomAppOpen / the open ios_cxr_l_sample TODO.
            let error = CxrClient.shared.sendCustomCmd(
                cmd: TransportConstants.cxrPhoneToGlassesCommand,
                payload: data,
                callback: callback
            )
            if let error {
                handleImmediateError(error, context: "global send")
                if String(describing: error).contains("notReady") {
                    reopenCustomAppForSendNotReady()
                    queueForChannelRefresh(pending, reason: "immediate \(error)")
                    return
                }
                retry(pending, reason: "immediate \(error)")
            }
        }

        private func enqueue(_ pending: PendingMessage) {
            if let key = coalesceKey(for: pending.message),
               let index = pendingMessages.firstIndex(where: { coalesceKey(for: $0.message) == key }) {
                pendingMessages[index] = pending
            } else if pending.priority {
                pendingMessages.insert(pending, at: 0)
            } else {
                pendingMessages.append(pending)
            }
            if pendingMessages.count > maxPendingMessages {
                pendingMessages.removeFirst(pendingMessages.count - maxPendingMessages)
            }
        }

        private func retry(_ pending: PendingMessage, reason: String) {
            guard pending.attempts < maxSendAttempts else {
                print("[RokidLyricsCXR] drop after attempts=\(pending.attempts) reason=\(reason) \(safeSummary(pending.message))")
                return
            }
            var next = pending
            next.attempts += 1
            print("[RokidLyricsCXR] retry queued attempt=\(next.attempts) reason=\(reason) \(safeSummary(next.message))")
            enqueue(next)
            scheduleFlushPending()
        }

        private func queueForChannelRefresh(_ pending: PendingMessage, reason: String) {
            guard pending.attempts < maxSendAttempts else {
                print("[RokidLyricsCXR] drop after attempts=\(pending.attempts) reason=\(reason) \(safeSummary(pending.message))")
                return
            }
            var next = pending
            next.attempts += 1
            print("[RokidLyricsCXR] queue until channel refresh attempt=\(next.attempts) reason=\(reason) \(safeSummary(next.message))")
            enqueue(next)
        }

        private func flushPending(reason: String) {
            guard protocolReady, didOpenCustomApp, !pendingMessages.isEmpty else { return }
            let drain = pendingMessages
            pendingMessages.removeAll()
            print("[RokidLyricsCXR] flushing \(drain.count) pending messages reason=\(reason)")
            drain.forEach { pending in
                var next = pending
                if next.attempts == 0 {
                    next.attempts = 1
                }
                sendNow(next)
            }
        }

        private func scheduleFlushPending() {
            guard !flushRetryScheduled else { return }
            flushRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.flushRetryScheduled = false
                    self.flushPending(reason: "retry")
                    if !self.pendingMessages.isEmpty {
                        self.scheduleFlushPending()
                    }
                }
            }
        }

        private func coalesceKey(for message: PhoneToGlassesMessage) -> String? {
            switch message {
            case .helloAck:
                return "helloAck"
            case .status:
                return "status"
            case .lyrics(.snapshot), .lyrics(.script):
                return "snapshot"
            case .lyrics(.window):
                return "window"
            case .lyrics(.sync):
                return "sync"
            case .lyrics(.error):
                return "lyricsError"
            case .error:
                return "error"
            }
        }

        private func safeSummary(_ message: PhoneToGlassesMessage) -> String {
            switch message {
            case .helloAck(let ack):
                return "helloAck(protocolVersion=\(ack.protocolVersion) capabilities=\(ack.capabilities.count))"
            case .status(let status):
                return "status(state=\(status.connectionState.rawValue) clients=\(status.bluetoothClientCount) notificationAccess=\(status.notificationAccessEnabled) hasError=\(status.lastError != nil))"
            case .lyrics(let event):
                return safeSummary(event)
            case .error(let message):
                return "runtime.error(chars=\(message.count))"
            }
        }

        private func safeSummary(_ event: LyricsEvent) -> String {
            switch event {
            case .snapshot(let snapshot):
                return "lyrics.snapshot(state=\(snapshot.sessionState.rawValue) revision=\(snapshot.revision) lines=\(snapshot.lines.count) plainChars=\(snapshot.plainLyrics.count) currentLine=\(snapshot.currentLineIndex) progressMs=\(snapshot.progressMs) synced=\(snapshot.synced))"
            case .window(let window):
                return "lyrics.window(state=\(window.sessionState.rawValue) revision=\(window.revision) lines=\(window.lines.count) currentLine=\(window.currentLineIndex) progressMs=\(window.progressMs))"
            case .script(let script):
                return "lyrics.script(state=\(script.sessionState.rawValue) revision=\(script.revision) bodyChars=\(script.body.count) encoding=\(script.encoding) currentLine=\(script.currentLineIndex) progressMs=\(script.progressMs))"
            case .sync(let sync):
                return "lyrics.sync(state=\(sync.sessionState.rawValue) revision=\(sync.revision) currentLine=\(sync.currentLineIndex) progressMs=\(sync.progressMs))"
            case .error(let message):
                return "lyrics.error(chars=\(message.count))"
            }
        }

        private func initializeClient() {
            // pageName MUST be the target glasses app package — the global queryApp/openApp/
            // sendCustomCmd operate on the app identified here. Leaving it nil is why those
            // returned false/notReady (the official ios_cxr_l_sample sets pageName to the glasses
            // package for customApp mode).
            let outcome = CxrClient.initialize(
                mode: .customApp,
                options: RGCxrClientInitializationOptions(
                    appDisplayName: "Rokid Lyrics",
                    pageName: TransportConstants.cxrCustomAppPackageName
                )
            )
            print("[RokidLyricsCXR] initialize outcome=\(outcome) mode=\(String(describing: CxrClient.initializationMode))")
            if outcome == .failureAlreadyInitialized,
               CxrClient.initializationMode != .customApp
            {
                status = DeviceStatus(
                    connectionState: .disconnected,
                    statusLabel: "CXR-L is already initialized in another mode.",
                    lastError: "CXR mode mismatch"
                )
            }
        }

        private func bindLegacyClientEvents() {
            CxrClient.shared.notifyEventPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    Task { @MainActor in
                        self?.handleNotify(event)
                    }
                }
                .store(in: &cancellables)

            CxrClient.shared.deviceInfoEventPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] deviceInfo in
                    Task { @MainActor in
                        self?.status = DeviceStatus(
                            connectionState: .connected,
                            statusLabel: "CXR-L connected to \(deviceInfo.deviceName ?? "Rokid glasses").",
                            bluetoothClientCount: 1
                        )
                    }
                }
                .store(in: &cancellables)

            // The global CxrClient.shared API is the correct custom-command path for a client
            // initialized in `.customApp` mode (session.commands/session.app return modeMismatch
            // in this mode — they are for customView). Register the listen channels globally.
            handleImmediateError(
                CxrClient.shared.setNotifyEventListenCmds([
                    TransportConstants.cxrGlassesToPhoneCommand,
                    TransportConstants.cxrPhoneToGlassesCommand,
                    TransportConstants.cxrLegacyLyricsCommand,
                ]),
                context: "global listen"
            )
        }

        private func bind(_ link: any RGCxrLink) {
            link.events.authStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    Task { @MainActor in
                        self?.handleAuthState(state)
                    }
                }
                .store(in: &cancellables)

            link.events.connectionStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] connected in
                    Task { @MainActor in
                        if connected {
                            self?.configureCustomAppSession()
                        } else {
                            self?.protocolReady = false
                            self?.subscriptionNotified = false
                            self?.status = DeviceStatus(
                                connectionState: .connecting,
                                statusLabel: "CXR-L link disconnected. BLE fallback remains active."
                            )
                        }
                    }
                }
                .store(in: &cancellables)
        }

        private func configureCustomAppSession() {
            print("[RokidLyricsCXR] configureCustomAppSession()")
            let link = self.link ?? CxrClient.makeLink(appDisplayName: "Rokid Lyrics")
            self.link = link
            // The session is used only for its lifecycle state (statePublisher drives readiness);
            // custom commands and app management go through the global CxrClient.shared API, which
            // is the correct path for `.customApp` mode.
            let session = self.session ?? (CxrClient.makeSession(
                RGCxrSessionConfig(
                    type: .customApp,
                    customAppPackageName: TransportConstants.cxrCustomAppPackageName,
                    appDisplayName: "Rokid Lyrics",
                    aiInterceptMode: .allowWithPause
                )
            ) as? any RGCxrCustomAppSession)
            guard let session else {
                status = DeviceStatus(
                    connectionState: .disconnected,
                    statusLabel: "CXR-L failed to create a custom app session.",
                    lastError: "Invalid CXR-L session type"
                )
                return
            }
            self.session = session
            print(
                "[RokidLyricsCXR] session config type=\(session.config.type) package=\(session.config.customAppPackageName ?? "nil") state=\(session.state.rawValue)"
            )

            bind(session)
            // NB: session.commands.setNotifyEventListenCmds returns modeMismatch on this SDK
            // build; the global CxrClient.setNotifyEventListenCmds (bindLegacyClientEvents) is the
            // one that actually carries the rk_custom_client/rk_custom_key channels. We re-issue
            // it (and the app open) only once the session is `.available` — see handleSessionState
            // / ensureCustomAppOpen. Firing app-management while the session is still `.unavailable`
            // is why openApp/queryApp came back false before.
            status = DeviceStatus(
                connectionState: .connecting,
                statusLabel: "CXR-L session configured. Waiting for it to become available.",
                bluetoothClientCount: 1
            )
        }

        private func bind(_ session: any RGCxrCustomAppSession) {
            session.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    Task { @MainActor in
                        self?.handleSessionState(event)
                    }
                }
                .store(in: &cancellables)

            session.commandEvents.notifyPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    Task { @MainActor in
                        self?.handleNotify(event)
                    }
                }
                .store(in: &cancellables)
        }

        private func handleAuthState(_ state: RGCxrClientAuthState) {
            print("[RokidLyricsCXR] authState \(safeAuthStateSummary(state))")
            switch state {
            case .notAuthenticated:
                protocolReady = false
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L is not authenticated.")
            case .authenticating:
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L authenticating with Rokid app.")
            case .authenticated:
                let deviceName = CxrClient.shared.auth.currentDeviceName
                status = DeviceStatus(
                    connectionState: .connecting,
                    statusLabel: "CXR-L authenticated\(deviceName.map { " with \($0)" } ?? "")."
                )
                configureCustomAppSession()
            case .expired:
                protocolReady = false
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L auth expired. Reconnect required.")
            case let .failed(error):
                protocolReady = false
                status = DeviceStatus(connectionState: .disconnected, statusLabel: "CXR-L auth failed: \(error)", lastError: error)
            @unknown default:
                protocolReady = false
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L auth state changed.")
            }
        }

        private func safeAuthStateSummary(_ state: RGCxrClientAuthState) -> String {
            switch state {
            case .notAuthenticated:
                return "notAuthenticated"
            case .authenticating:
                return "authenticating"
            case .authenticated:
                return "authenticated"
            case .expired:
                return "expired"
            case .failed:
                return "failed"
            @unknown default:
                return "unknown"
            }
        }

        private func handleSessionState(_ event: RGCxrSessionStateEvent) {
            print("[RokidLyricsCXR] sessionState \(event.state.rawValue)")
            switch event.state {
            case .available, .started:
                markProtocolReady()
                status = DeviceStatus(connectionState: .connected, statusLabel: "CXR-L session \(event.state.rawValue).", bluetoothClientCount: 1)
                // Now that the session is genuinely available, (re)register the global notify
                // channels and open the custom app to bind the bidirectional channel. Retried
                // because the first openApp can land before the link has fully settled.
                if !openLoopActive, !didOpenCustomApp {
                    openLoopActive = true
                    openAttempts = 0
                    ensureCustomAppOpen()
                }
            case .paused:
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L session paused.")
            case .unavailable:
                protocolReady = false
                subscriptionNotified = false
                openLoopActive = false
                didOpenCustomApp = false
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L session unavailable.")
            @unknown default:
                protocolReady = false
                subscriptionNotified = false
                openLoopActive = false
                didOpenCustomApp = false
                status = DeviceStatus(connectionState: .connecting, statusLabel: "CXR-L session state changed.")
            }
        }

        private func sendTottiPong() {

            guard let jsonData =
                #"{"type":"totti_pong","message":"TOTTI_PONG"}"#
                    .data(using: .utf8)
            else {
                print("[TottiBridge] failed to create PONG payload")
                return
            }

            let data =
                CxrCapsCodec.encodeBinaryPayload(
                    jsonData
                )

            print(
                "[TottiBridge] sending TOTTI_PONG bytes=\(data.count)"
            )

            let callback:
                (Bool, Data?, Int32?, String?) -> Void =
            {
                success,
                _,
                errorCode,
                errorMessage in

                print(
                    "[TottiBridge] PONG callback success=\(success) code=\(errorCode ?? 0) message=\(errorMessage ?? "")"
                )
            }

            let error =
                CxrClient.shared.sendCustomCmd(
                    cmd:
                        TransportConstants
                            .cxrPhoneToGlassesCommand,
                    payload:
                        data,
                    callback:
                        callback
                )

            if let error {

                handleImmediateError(
                    error,
                    context: "totti pong"
                )
            }
        }

        private func handleNotify(
            _ event: RGCxrClientNotifyEvent
        ) {

            print(
                "[RokidLyricsCXR] notify cmd=\(event.cmd) subCmd=\(event.subCmd) payload=\(event.payload?.count ?? 0) payloadEx=\(event.payloadEx?.count ?? 0)"
            )

            logger.info(
                "CXR-L notify cmd=\(event.cmd, privacy: .public) subCmd=\(event.subCmd, privacy: .public) payload=\(event.payload?.count ?? 0) payloadEx=\(event.payloadEx?.count ?? 0)"
            )

            guard
                event.cmd ==
                    TransportConstants
                        .cxrGlassesToPhoneCommand ||

                event.cmd ==
                    TransportConstants
                        .cxrPhoneToGlassesCommand ||

                event.subCmd ==
                    TransportConstants
                        .cxrGlassesToPhoneCommand ||

                event.subCmd ==
                    TransportConstants
                        .cxrPhoneToGlassesCommand ||

                event.cmd ==
                    TransportConstants
                        .cxrLegacyLyricsCommand ||

                event.subCmd ==
                    TransportConstants
                        .cxrLegacyLyricsCommand
            else {
                return
            }

            // CXR-L forwards the first Caps string as subCmd. The PING
            // can therefore arrive without either payload field populated.
            if let subCommandData = event.subCmd.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: subCommandData),
               let fields = object as? [String: Any],
               fields["type"] as? String == "totti_ping" {
                print("[TottiBridge] received TOTTI_PING via subCmd")
                sendTottiPong()
                return
            }

            guard
                let data =
                    event.payload ??
                    event.payloadEx,

                let json =
                    CxrCapsCodec
                        .decodeJSONPayload(
                            data
                        )
            else {

                logger.warning(
                    "Dropped unparseable CXR-L notify"
                )

                return
            }

            if
                json.contains(
                    "\"type\":\"totti_ping\""
                ) ||
                json.contains(
                    "TOTTI_PING"
                )
            {

                print(
                    "[TottiBridge] received TOTTI_PING"
                )

                sendTottiPong()

                return
            }

            guard
                let message =
                    WireProtocol
                        .decodeGlassesMessage(
                            json
                        )
            else {

                logger.warning(
                    "Dropped unknown CXR-L message"
                )

                return
            }

            onMessage?(
                message
            )
        }

        private func ensureCustomAppOpen(force: Bool = false) {
            guard force || !didOpenCustomApp else { return }
            openAttempts += 1
            print("[RokidLyricsCXR] ensureCustomAppOpen attempt=\(openAttempts)")

            // Re-register the global notify channels now that the link is genuinely up.
            handleImmediateError(
                CxrClient.shared.setNotifyEventListenCmds([
                    TransportConstants.cxrGlassesToPhoneCommand,
                    TransportConstants.cxrPhoneToGlassesCommand,
                    TransportConstants.cxrLegacyLyricsCommand,
                ]),
                context: "re-register listen"
            )

            // Diagnostic only — queryApp is an unreliable false-negative over a fresh link, so we
            // never gate on it and never upload/install (the glasses app is side-loaded already).
            CxrClient.shared.queryApp { installed in
                print("[RokidLyricsCXR] queryApp installed=\(installed)")
            }

            let activityCandidates = [
                TransportConstants.cxrCustomAppActivityName,
            ]
            for activityName in activityCandidates {
                handleImmediateError(
                    CxrClient.shared.openApp(activityName: activityName, url: "") { [weak self] started in
                        print("[RokidLyricsCXR] openApp activity=\(activityName) started=\(started)")
                        guard started else { return }
                        Task { @MainActor in self?.onCustomAppOpened(force: force) }
                    },
                    context: "openApp \(activityName)"
                )
            }

            // Retry: the custom-app channel sometimes needs a couple of seconds after the session
            // reports `.available` before openApp / send report ready.
            if openAttempts < maxOpenAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.openLoopActive, force || !self.didOpenCustomApp else { return }
                        self.ensureCustomAppOpen(force: force)
                    }
                }
            } else {
                // The openApp *result* (started=true) has to travel back over the glasses→phone
                // reverse channel, which is unreliable on this link ("bluetooth device not
                // connected"), so the confirmation callback may never arrive even though the glasses
                // app already launched and is sitting at "waiting for the phone BT link". Gating all
                // sends on that confirmation forever guarantees a stuck link. The forward channel and
                // the app are up, so proceed optimistically: bind the channel and start sending
                // (helloAck + window). If the glasses genuinely never receive payloads, their log
                // will show it — but at least the phone now talks.
                print("[RokidLyricsCXR] ensureCustomAppOpen exhausted retries; proceeding optimistically on session readiness")
                onCustomAppOpened(force: true)
            }
        }

        private func reopenCustomAppForSendNotReady() {
            guard !openLoopActive else { return }
            print("[RokidLyricsCXR] send notReady; refreshing custom app channel")
            openLoopActive = true
            openAttempts = 0
            ensureCustomAppOpen(force: true)
        }

        private func onCustomAppOpened(force: Bool = false) {
            guard !didOpenCustomApp || openLoopActive else { return }
            didOpenCustomApp = true
            openLoopActive = false
            print("[RokidLyricsCXR] custom app opened; channel bound")
            status = DeviceStatus(
                connectionState: .connected,
                statusLabel: "CXR-L ready. Rokid Lyrics glasses app is running.",
                bluetoothClientCount: 1
            )
            markProtocolReady(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                Task { @MainActor in
                    self?.flushPending(reason: "custom app opened")
                }
            }
        }

        private func handleImmediateError(_ error: RGCxrClientError?, context: String = "sdk call") {
            guard let error else { return }
            print("[RokidLyricsCXR] immediate error \(context): \(error)")
            logger.error("CXR-L error: \(String(describing: error), privacy: .public)")
            status = DeviceStatus(
                connectionState: .connecting,
                statusLabel: "CXR-L not ready: \(String(describing: error))",
                lastError: String(describing: error)
            )
        }

        private func markProtocolReady(force: Bool = false) {
            protocolReady = true
            if force {
                subscriptionNotified = false
            }
            guard didOpenCustomApp else { return }
            guard !subscriptionNotified else { return }
            subscriptionNotified = true
            print("[RokidLyricsCXR] subscribed")
            onSubscribed?()
        }
    #endif
}
