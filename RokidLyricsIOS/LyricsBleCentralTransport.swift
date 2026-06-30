import Combine
import CoreBluetooth
import Foundation
import OSLog

@MainActor
final class LyricsBleCentralTransport: NSObject, ObservableObject {
    @Published private(set) var status = DeviceStatus(
        connectionState: .connecting,
        statusLabel: "BLE scanning for Rokid Lyrics glasses."
    )

    var onMessage: ((GlassesToPhoneMessage) -> Void)?
    var onSubscribed: (() -> Void)?

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var outgoingFrames: [Data] = []
    private var writeInFlight = false
    private var inFlightFrame: Data?
    private var inFlightRetries = 0
    private let maxFrameRetries = 4
    private var nextMessageId = UInt32.random(in: 1..<UInt32.max)
    private var repairTimer: Timer?
    private var linkStartedAt: Date?
    private var resolvingGatt = false
    private let reassembler = BleWireFramer.Reassembler()
    private let logger = Logger(subsystem: "app.nectarine4657.lime425", category: "BLE")

    private let serviceUUID = CBUUID(string: TransportConstants.bleServiceUUID)
    private let rxUUID = CBUUID(string: TransportConstants.bleRXCharacteristicUUID)
    private let txUUID = CBUUID(string: TransportConstants.bleTXCharacteristicUUID)
    private let handshakeTimeout: TimeInterval = 8

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "rokid.lyrics.ble.central"]
        )
        startRepairTimer()
    }

    deinit {
        repairTimer?.invalidate()
    }

    var isConnected: Bool {
        status.connectionState == .connected
    }

    func send(_ message: PhoneToGlassesMessage, priority: Bool = false) {
        guard let json = try? WireProtocol.encodePhoneMessage(message) else { return }
        let packetSize = maxPacketSize()
        let frames = BleWireFramer.encode(message: json, messageId: nextMessageId, maxPacketSize: packetSize)
        nextMessageId &+= 1
        guard !frames.isEmpty else { return }
        print("[RokidLyricsBLE] send bytes=\(json.utf8.count) frames=\(frames.count) packetSize=\(packetSize) priority=\(priority) queued=\(outgoingFrames.count)")
        if priority {
            // A priority message supersedes anything still queued, but not a frame
            // already on the wire (its write callback will pump the new queue).
            outgoingFrames.removeAll()
            outgoingFrames.append(contentsOf: frames)
        } else {
            outgoingFrames.append(contentsOf: frames)
        }
        pumpWriteQueue()
    }

    func dropQueuedWrites() {
        outgoingFrames.removeAll()
    }

    private func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            return
        }
        cancelStaleConnectedPeripherals()
        logger.info("Scanning for Rokid Lyrics BLE service")
        status = DeviceStatus(connectionState: .connecting, statusLabel: "Scanning for Rokid Lyrics BLE glasses.")
        centralManager?.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startRepairTimer() {
        repairTimer?.invalidate()
        repairTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.repairConnectionIfNeeded()
            }
        }
    }

    private func repairConnectionIfNeeded() {
        guard centralManager?.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected {
            if status.connectionState != .connected,
               let linkStartedAt,
               Date().timeIntervalSince(linkStartedAt) > handshakeTimeout {
                logger.warning("BLE handshake timed out; forcing a fresh scan")
                centralManager?.cancelPeripheralConnection(peripheral)
                markDisconnected("BLE handshake timed out. Scanning again.")
                return
            }
            peripheral.delegate = self
            if rxCharacteristic == nil || txCharacteristic == nil {
                if !resolvingGatt {
                    resolvingGatt = true
                    status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE connected. Refreshing Lyrics service.")
                    if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
                        logger.info("Refreshing BLE characteristics")
                        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
                    } else {
                        logger.info("Refreshing BLE services")
                        peripheral.discoverServices([serviceUUID])
                    }
                }
                return
            }
            if let txCharacteristic, !txCharacteristic.isNotifying {
                if !resolvingGatt {
                    resolvingGatt = true
                    status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE connected. Resubscribing to Lyrics notifications.")
                    logger.info("Requesting BLE notification resubscribe")
                    peripheral.setNotifyValue(true, for: txCharacteristic)
                }
                return
            }
            pumpWriteQueue()
            return
        }
        startScanning()
    }

    private func cancelStaleConnectedPeripherals() {
        guard let centralManager else { return }
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [serviceUUID])
        for existing in connected where existing.identifier != peripheral?.identifier {
            logger.info("Cancelling stale connected BLE peripheral before scan")
            existing.delegate = nil
            centralManager.cancelPeripheralConnection(existing)
        }
    }

    private func attach(_ peripheral: CBPeripheral, label: String) {
        if let current = self.peripheral,
           current.identifier != peripheral.identifier,
           current.state == .connecting || current.state == .connected {
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        linkStartedAt = Date()
        resolvingGatt = false
        rxCharacteristic = nil
        txCharacteristic = nil
        status = DeviceStatus(connectionState: .connecting, statusLabel: label)
        logger.info("Attaching BLE peripheral \(peripheral.identifier.uuidString, privacy: .public), state=\(peripheral.state.rawValue)")
        centralManager?.stopScan()
        if peripheral.state == .connected {
            peripheral.discoverServices([serviceUUID])
        } else {
            centralManager?.connect(peripheral, options: nil)
        }
    }

    private func maxPacketSize() -> Int {
        // Use the negotiated ATT MTU instead of the 23-byte default. The value for
        // `.withoutResponse` is exactly ATT_MTU - 3, so sizing each `.withResponse`
        // frame to it keeps every write in a single GATT packet (no long writes) —
        // which the glasses reassembler can receive intact — while cutting a song
        // window from dozens of 11-byte chunks down to a handful.
        guard let peripheral else { return 20 }
        let writable = peripheral.maximumWriteValueLength(for: .withoutResponse)
        return max(20, min(writable, 512))
    }

    private func pumpWriteQueue() {
        guard !writeInFlight,
              let peripheral,
              let rxCharacteristic,
              peripheral.state == .connected,
              !outgoingFrames.isEmpty else { return }

        let frame = outgoingFrames.removeFirst()
        inFlightFrame = frame
        writeInFlight = true
        peripheral.writeValue(frame, for: rxCharacteristic, type: .withResponse)
    }

    private func handleIncoming(_ data: Data) {
        guard let line = reassembler.accept(data),
              let message = WireProtocol.decodeGlassesMessage(line) else { return }
        onMessage?(message)
    }

    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        peripheral?.identifier == candidate.identifier
    }

    private func markDisconnected(_ label: String) {
        status = DeviceStatus(connectionState: .connecting, statusLabel: label)
        rxCharacteristic = nil
        txCharacteristic = nil
        outgoingFrames.removeAll()
        writeInFlight = false
        inFlightFrame = nil
        inFlightRetries = 0
        nextMessageId = UInt32.random(in: 1..<UInt32.max)
        linkStartedAt = nil
        resolvingGatt = false
        reassembler.clear()
        peripheral = nil
        startScanning()
    }
}

extension LyricsBleCentralTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                startScanning()
            case .poweredOff:
                status = DeviceStatus(connectionState: .disconnected, statusLabel: "Bluetooth is off on iPhone.")
            case .unauthorized:
                status = DeviceStatus(connectionState: .disconnected, statusLabel: "Bluetooth permission denied on iPhone.")
            case .unsupported:
                status = DeviceStatus(connectionState: .disconnected, statusLabel: "Bluetooth LE is unsupported on this iPhone.")
            default:
                status = DeviceStatus(connectionState: .connecting, statusLabel: "Bluetooth is not ready yet.")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        Task { @MainActor in
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               !peripherals.isEmpty {
                logger.info("Dropping restored BLE peripherals and starting a fresh scan")
                for restored in peripherals {
                    restored.delegate = nil
                    central.cancelPeripheralConnection(restored)
                }
                markDisconnected("Restored BLE state. Scanning again.")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            if let current = self.peripheral,
               current.identifier != peripheral.identifier,
               current.state == .connecting || current.state == .connected {
                return
            }
            attach(peripheral, label: "Found Rokid Lyrics BLE. Connecting.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrent(peripheral) else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            self.peripheral = peripheral
            peripheral.delegate = self
            linkStartedAt = Date()
            resolvingGatt = true
            status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE connected. Discovering Lyrics service.")
            logger.info("BLE didConnect; discovering service")
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            markDisconnected(error?.localizedDescription ?? "BLE connect failed. Scanning again.")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            logger.info("BLE didDisconnect: \(error?.localizedDescription ?? "no error", privacy: .public)")
            markDisconnected(error?.localizedDescription ?? "BLE disconnected. Scanning again.")
        }
    }
}

extension LyricsBleCentralTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            if let error {
                resolvingGatt = false
                markDisconnected(error.localizedDescription)
                return
            }
            let service = peripheral.services?.first { $0.uuid == serviceUUID }
            guard let service else {
                resolvingGatt = false
                markDisconnected("Rokid Lyrics BLE service missing.")
                return
            }
            logger.info("BLE service discovered; discovering characteristics")
            peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            if let error {
                resolvingGatt = false
                markDisconnected(error.localizedDescription)
                return
            }
            rxCharacteristic = service.characteristics?.first { $0.uuid == rxUUID }
            txCharacteristic = service.characteristics?.first { $0.uuid == txUUID }
            guard let txCharacteristic, rxCharacteristic != nil else {
                resolvingGatt = false
                logger.error("BLE characteristics missing after discovery")
                markDisconnected("Rokid Lyrics BLE characteristics missing.")
                return
            }
            logger.info("BLE characteristics discovered; enabling notifications")
            peripheral.setNotifyValue(true, for: txCharacteristic)
            status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE ready. Waiting for Lyrics handshake.")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            if let error {
                resolvingGatt = false
                logger.error("BLE notification subscription failed: \(error.localizedDescription, privacy: .public)")
                markDisconnected(error.localizedDescription)
                return
            }
            resolvingGatt = false
            if characteristic.uuid == txUUID, characteristic.isNotifying {
                outgoingFrames.removeAll()
                writeInFlight = false
                inFlightFrame = nil
                inFlightRetries = 0
                nextMessageId = UInt32.random(in: 1..<UInt32.max)
                linkStartedAt = nil
                reassembler.clear()
                logger.info("BLE notifications enabled")
                status = DeviceStatus(connectionState: .connected, statusLabel: "BLE subscribed to Rokid Lyrics glasses.", bluetoothClientCount: 1)
                onSubscribed?()
                pumpWriteQueue()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, characteristic.uuid == txUUID, let data = characteristic.value else { return }
            guard isCurrent(peripheral) else { return }
            handleIncoming(data)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            writeInFlight = false
            if let error {
                // Retry the same frame a few times before giving up. Re-sending a
                // frame is safe: the glasses reassembler keys by messageId+chunkIndex,
                // so a duplicate just overwrites the same slot. This stops a single
                // transient write error from silently dropping a whole window/script.
                if inFlightRetries < maxFrameRetries, let frame = inFlightFrame, peripheral.state == .connected {
                    inFlightRetries += 1
                    logger.warning("BLE write failed (retry \(self.inFlightRetries)/\(self.maxFrameRetries)): \(error.localizedDescription, privacy: .public)")
                    outgoingFrames.insert(frame, at: 0)
                    inFlightFrame = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        Task { @MainActor in self?.pumpWriteQueue() }
                    }
                    return
                }
                logger.error("BLE write failed permanently; dropping queue: \(error.localizedDescription, privacy: .public)")
                inFlightFrame = nil
                inFlightRetries = 0
                status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE write failed: \(error.localizedDescription)")
                outgoingFrames.removeAll()
                return
            }
            inFlightFrame = nil
            inFlightRetries = 0
            pumpWriteQueue()
        }
    }
}
