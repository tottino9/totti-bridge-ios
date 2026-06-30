import Combine
import Foundation

@MainActor
final class LyricsGlassesTransport: ObservableObject {
    enum ActiveRoute {
        case cxr
        case bleCentral
        case blePeripheral
    }

    @Published private(set) var status = DeviceStatus(
        connectionState: .connecting,
        statusLabel: "Preparing Rokid glasses transports."
    )

    var onMessage: ((GlassesToPhoneMessage) -> Void)?
    var onSubscribed: (() -> Void)?

    private let cxrTransport = LyricsCxrTransport()
    private let bleTransport = LyricsBleCentralTransport()
    private let blePeripheralTransport = LyricsBlePeripheralTransport()
    private var cancellables = Set<AnyCancellable>()

    init() {
        cxrTransport.onMessage = { [weak self] message in
            self?.onMessage?(message)
        }
        cxrTransport.onSubscribed = { [weak self] in
            self?.onSubscribed?()
        }
        bleTransport.onMessage = { [weak self] message in
            self?.onMessage?(message)
        }
        bleTransport.onSubscribed = { [weak self] in
            guard self?.cxrTransport.isConnected != true,
                  self?.blePeripheralTransport.isConnected != true else { return }
            self?.onSubscribed?()
        }
        blePeripheralTransport.onMessage = { [weak self] message in
            self?.onMessage?(message)
        }
        blePeripheralTransport.onSubscribed = { [weak self] in
            self?.onSubscribed?()
        }

        cxrTransport.$status
            .combineLatest(bleTransport.$status)
            .combineLatest(blePeripheralTransport.$status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transportStatuses, peripheralStatus in
                Task { @MainActor in
                    self?.status = Self.combinedStatus(
                        cxr: transportStatuses.0,
                        bleCentral: transportStatuses.1,
                        blePeripheral: peripheralStatus
                    )
                }
            }
            .store(in: &cancellables)
    }

    func authenticateCxr() {
        cxrTransport.authenticate()
    }

    func handleOpenURL(_ url: URL) -> Bool {
        cxrTransport.handleOpenURL(url)
    }

    func send(_ message: PhoneToGlassesMessage, priority: Bool = false) {
        if blePeripheralTransport.isConnected {
            blePeripheralTransport.send(message, priority: priority)
        } else if cxrTransport.isConnected {
            cxrTransport.send(message, priority: priority)
            if shouldMirrorToBle(message, priority: priority), bleTransport.isConnected {
                bleTransport.send(message, priority: priority)
            }
        } else {
            bleTransport.send(message, priority: priority)
        }
    }

    var activeRoute: ActiveRoute {
        if blePeripheralTransport.isConnected {
            return .blePeripheral
        }
        if cxrTransport.isConnected {
            return .cxr
        }
        return .bleCentral
    }

    func dropQueuedWrites() {
        cxrTransport.dropQueuedWrites()
        bleTransport.dropQueuedWrites()
        blePeripheralTransport.dropQueuedWrites()
    }

    private func shouldMirrorToBle(_ message: PhoneToGlassesMessage, priority: Bool) -> Bool {
        if priority { return true }
        if case .lyrics(.sync) = message { return true }
        return false
    }

    private static func combinedStatus(
        cxr: DeviceStatus,
        bleCentral: DeviceStatus,
        blePeripheral: DeviceStatus
    ) -> DeviceStatus {
        if blePeripheral.connectionState == .connected {
            return DeviceStatus(
                connectionState: .connected,
                statusLabel: "\(blePeripheral.statusLabel) CXR-L: \(cxr.statusLabel)",
                bluetoothClientCount: blePeripheral.bluetoothClientCount,
                notificationAccessEnabled: blePeripheral.notificationAccessEnabled || cxr.notificationAccessEnabled,
                lastError: blePeripheral.lastError ?? cxr.lastError
            )
        }
        if cxr.connectionState == .connected {
            return cxr
        }
        if bleCentral.connectionState == .connected {
            return DeviceStatus(
                connectionState: .connected,
                statusLabel: "\(bleCentral.statusLabel) CXR-L: \(cxr.statusLabel)",
                bluetoothClientCount: bleCentral.bluetoothClientCount,
                notificationAccessEnabled: bleCentral.notificationAccessEnabled,
                lastError: bleCentral.lastError ?? cxr.lastError
            )
        }
        return DeviceStatus(
            connectionState: cxr.connectionState == .connecting ||
                bleCentral.connectionState == .connecting ||
                blePeripheral.connectionState == .connecting ? .connecting : .disconnected,
            statusLabel: "CXR-L: \(cxr.statusLabel) BLE client: \(bleCentral.statusLabel) BLE host: \(blePeripheral.statusLabel)",
            bluetoothClientCount: max(cxr.bluetoothClientCount, max(bleCentral.bluetoothClientCount, blePeripheral.bluetoothClientCount)),
            notificationAccessEnabled: cxr.notificationAccessEnabled || bleCentral.notificationAccessEnabled || blePeripheral.notificationAccessEnabled,
            lastError: cxr.lastError ?? bleCentral.lastError ?? blePeripheral.lastError
        )
    }
}
