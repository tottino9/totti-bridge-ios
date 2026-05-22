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

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var outgoingFrames: [Data] = []
    private var writeInFlight = false
    private var nextMessageId: UInt32 = 1
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
    }

    var isConnected: Bool {
        status.connectionState == .connected
    }

    func send(_ message: PhoneToGlassesMessage) {
        guard let json = try? WireProtocol.encodePhoneMessage(message) else { return }
        let packetSize = maxPacketSize()
        let frames = BleWireFramer.encode(message: json, messageId: nextMessageId, maxPacketSize: packetSize)
        nextMessageId &+= 1
        guard !frames.isEmpty else { return }
        outgoingFrames.append(contentsOf: frames)
        pumpWriteQueue()
    }

    private func startScanning() {
        guard centralManager?.state == .poweredOn else { return }
        status = DeviceStatus(connectionState: .connecting, statusLabel: "Scanning for Rokid Lyrics BLE glasses.")
        centralManager?.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func maxPacketSize() -> Int {
        guard let peripheral else { return 20 }
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        return min(max(maxWrite, 20), 180)
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

    private func markDisconnected(_ label: String) {
        status = DeviceStatus(connectionState: .connecting, statusLabel: label)
        rxCharacteristic = nil
        txCharacteristic = nil
        outgoingFrames.removeAll()
        writeInFlight = false
        reassembler.clear()
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
                peripheral = restored
                peripheral?.delegate = self
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
            self.peripheral = peripheral
            peripheral.delegate = self
            status = DeviceStatus(connectionState: .connecting, statusLabel: "Found Rokid Lyrics BLE. Connecting.")
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
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
            markDisconnected(error?.localizedDescription ?? "BLE connect failed. Scanning again.")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            markDisconnected(error?.localizedDescription ?? "BLE disconnected. Scanning again.")
        }
    }
}

extension LyricsBleCentralTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
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
            if let error {
                markDisconnected(error.localizedDescription)
                return
            }
            if characteristic.uuid == txUUID, characteristic.isNotifying {
                status = DeviceStatus(connectionState: .connected, statusLabel: "BLE subscribed to Rokid Lyrics glasses.", bluetoothClientCount: 1)
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
            handleIncoming(data)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
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
