import Combine
import CoreBluetooth
import Foundation

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
    private var nextMessageId = UInt32.random(in: 1..<UInt32.max)
    private var repairTimer: Timer?
    private let reassembler = BleWireFramer.Reassembler()

    private let serviceUUID = CBUUID(string: TransportConstants.bleServiceUUID)
    private let rxUUID = CBUUID(string: TransportConstants.bleRXCharacteristicUUID)
    private let txUUID = CBUUID(string: TransportConstants.bleTXCharacteristicUUID)

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
        if priority {
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
        if attachConnectedPeripheralIfAvailable() {
            return
        }
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
            peripheral.delegate = self
            if rxCharacteristic == nil || txCharacteristic == nil {
                status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE connected. Refreshing Lyrics service.")
                if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
                    peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
                } else {
                    peripheral.discoverServices([serviceUUID])
                }
                return
            }
            if let txCharacteristic, !txCharacteristic.isNotifying {
                status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE connected. Resubscribing to Lyrics notifications.")
                peripheral.setNotifyValue(true, for: txCharacteristic)
                return
            }
            pumpWriteQueue()
            return
        }
        startScanning()
    }

    private func attachConnectedPeripheralIfAvailable() -> Bool {
        guard let centralManager else { return false }
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            return true
        }
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [serviceUUID])
        guard let existing = connected.first else { return false }
        attach(existing, label: "Found already-connected Rokid Lyrics BLE. Refreshing.")
        return true
    }

    private func attach(_ peripheral: CBPeripheral, label: String) {
        if let current = self.peripheral,
           current.identifier != peripheral.identifier,
           current.state == .connecting || current.state == .connected {
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        status = DeviceStatus(connectionState: .connecting, statusLabel: label)
        centralManager?.stopScan()
        if peripheral.state == .connected {
            peripheral.discoverServices([serviceUUID])
        } else {
            centralManager?.connect(peripheral, options: nil)
        }
    }

    private func maxPacketSize() -> Int {
        20
    }

    private func pumpWriteQueue() {
        guard !writeInFlight,
              let peripheral,
              let rxCharacteristic,
              peripheral.state == .connected,
              !outgoingFrames.isEmpty else { return }

        let frame = outgoingFrames.removeFirst()
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
        nextMessageId = UInt32.random(in: 1..<UInt32.max)
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
               let restored = peripherals.first {
                attach(restored, label: "Restored Rokid Lyrics BLE connection.")
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
            status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE connected. Discovering Lyrics service.")
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
            markDisconnected(error?.localizedDescription ?? "BLE disconnected. Scanning again.")
        }
    }
}

extension LyricsBleCentralTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrent(peripheral) else { return }
            if let error {
                markDisconnected(error.localizedDescription)
                return
            }
            let service = peripheral.services?.first { $0.uuid == serviceUUID }
            guard let service else {
                markDisconnected("Rokid Lyrics BLE service missing.")
                return
            }
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
                markDisconnected(error.localizedDescription)
                return
            }
            rxCharacteristic = service.characteristics?.first { $0.uuid == rxUUID }
            txCharacteristic = service.characteristics?.first { $0.uuid == txUUID }
            guard let txCharacteristic, rxCharacteristic != nil else {
                markDisconnected("Rokid Lyrics BLE characteristics missing.")
                return
            }
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
                markDisconnected(error.localizedDescription)
                return
            }
            if characteristic.uuid == txUUID, characteristic.isNotifying {
                outgoingFrames.removeAll()
                writeInFlight = false
                nextMessageId = UInt32.random(in: 1..<UInt32.max)
                reassembler.clear()
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
        guard error == nil, characteristic.uuid == txUUID, let data = characteristic.value else { return }
        Task { @MainActor in
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
                status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE write failed: \(error.localizedDescription)")
                outgoingFrames.removeAll()
                return
            }
            pumpWriteQueue()
        }
    }
}
