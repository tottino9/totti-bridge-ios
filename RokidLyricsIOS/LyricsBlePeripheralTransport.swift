import Combine
import CoreBluetooth
import Foundation
import OSLog

@MainActor
final class LyricsBlePeripheralTransport: NSObject, ObservableObject {
    @Published private(set) var status = DeviceStatus(
        connectionState: .connecting,
        statusLabel: "BLE advertising Rokid Lyrics from iPhone."
    )

    var onMessage: ((GlassesToPhoneMessage) -> Void)?
    var onSubscribed: (() -> Void)?

    private var peripheralManager: CBPeripheralManager?
    private var rxCharacteristic: CBMutableCharacteristic?
    private var txCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var outgoingFrames: [Data] = []
    private var nextMessageId = UInt32.random(in: 1..<UInt32.max)
    private let reassembler = BleWireFramer.Reassembler()
    private let logger = Logger(subsystem: "app.nectarine4657.lime425", category: "BLEPeripheral")

    private let serviceUUID = CBUUID(string: TransportConstants.bleServiceUUID)
    private let rxUUID = CBUUID(string: TransportConstants.bleRXCharacteristicUUID)
    private let txUUID = CBUUID(string: TransportConstants.bleTXCharacteristicUUID)

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "rokid.lyrics.ble.peripheral"]
        )
    }

    var isConnected: Bool {
        !subscribedCentrals.isEmpty
    }

    func send(_ message: PhoneToGlassesMessage, priority: Bool = false) {
        guard isConnected,
              let json = try? WireProtocol.encodePhoneMessage(message)
        else { return }

        let packetSize = maxPacketSize()
        let frames = BleWireFramer.encode(message: json, messageId: nextMessageId, maxPacketSize: packetSize)
        nextMessageId &+= 1
        guard !frames.isEmpty else { return }

        logger.info("Queueing peripheral BLE message bytes=\(json.utf8.count) frames=\(frames.count) packetSize=\(packetSize) priority=\(priority)")
        if priority {
            outgoingFrames.removeAll()
        }
        outgoingFrames.append(contentsOf: frames)
        pumpNotifyQueue()
    }

    func dropQueuedWrites() {
        outgoingFrames.removeAll()
    }

    private func installGattService() {
        guard peripheralManager?.state == .poweredOn else { return }

        let rxCharacteristic = CBMutableCharacteristic(
            type: rxUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let txCharacteristic = CBMutableCharacteristic(
            type: txUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [rxCharacteristic, txCharacteristic]

        self.rxCharacteristic = rxCharacteristic
        self.txCharacteristic = txCharacteristic
        peripheralManager?.removeAllServices()
        peripheralManager?.add(service)
        status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE peripheral service starting.")
    }

    private func startAdvertising() {
        guard peripheralManager?.state == .poweredOn else { return }
        if peripheralManager?.isAdvertising == true { return }
        peripheralManager?.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: TransportConstants.bluetoothServiceName,
        ])
        status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE advertising Lyrics service from iPhone.")
    }

    private func stopAdvertisingAndReset(_ label: String, state: ConnectionState = .connecting, lastError: String? = nil) {
        peripheralManager?.stopAdvertising()
        subscribedCentrals.removeAll()
        outgoingFrames.removeAll()
        nextMessageId = UInt32.random(in: 1..<UInt32.max)
        reassembler.clear()
        status = DeviceStatus(connectionState: state, statusLabel: label, lastError: lastError)
    }

    private func maxPacketSize() -> Int {
        let negotiated = subscribedCentrals.values
            .map(\.maximumUpdateValueLength)
            .filter { $0 > 0 }
            .min() ?? 20
        return max(20, min(negotiated, 512))
    }

    private func pumpNotifyQueue() {
        guard let peripheralManager,
              let txCharacteristic,
              isConnected,
              !outgoingFrames.isEmpty
        else { return }

        while !outgoingFrames.isEmpty {
            let frame = outgoingFrames[0]
            let accepted = peripheralManager.updateValue(frame, for: txCharacteristic, onSubscribedCentrals: nil)
            if accepted {
                outgoingFrames.removeFirst()
            } else {
                logger.debug("Peripheral notify backpressure; waiting for ready callback")
                break
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let line = reassembler.accept(data),
              let message = WireProtocol.decodeGlassesMessage(line)
        else { return }
        onMessage?(message)
    }
}

extension LyricsBlePeripheralTransport: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                installGattService()
            case .poweredOff:
                stopAdvertisingAndReset("Bluetooth is off on iPhone.", state: .disconnected)
            case .unauthorized:
                stopAdvertisingAndReset("Bluetooth permission denied on iPhone.", state: .disconnected)
            case .unsupported:
                stopAdvertisingAndReset("Bluetooth LE peripheral mode is unsupported on this iPhone.", state: .disconnected)
            default:
                stopAdvertisingAndReset("Bluetooth peripheral mode is not ready yet.")
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        Task { @MainActor in
            subscribedCentrals.removeAll()
            outgoingFrames.removeAll()
            reassembler.clear()
            if peripheral.state == .poweredOn {
                installGattService()
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                status = DeviceStatus(
                    connectionState: .disconnected,
                    statusLabel: "BLE peripheral service failed: \(error.localizedDescription)",
                    lastError: error.localizedDescription
                )
                return
            }
            logger.info("BLE peripheral service added; advertising")
            startAdvertising()
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                status = DeviceStatus(
                    connectionState: .disconnected,
                    statusLabel: "BLE advertising failed: \(error.localizedDescription)",
                    lastError: error.localizedDescription
                )
            } else {
                status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE advertising Lyrics service from iPhone.")
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            guard characteristic.uuid == txUUID else { return }
            subscribedCentrals[central.identifier] = central
            logger.info("BLE central subscribed \(central.identifier.uuidString, privacy: .public) mtu=\(central.maximumUpdateValueLength)")
            status = DeviceStatus(
                connectionState: .connected,
                statusLabel: "BLE inverted link ready. Rokid glasses subscribed to iPhone.",
                bluetoothClientCount: subscribedCentrals.count
            )
            onSubscribed?()
            pumpNotifyQueue()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            guard characteristic.uuid == txUUID else { return }
            subscribedCentrals.removeValue(forKey: central.identifier)
            outgoingFrames.removeAll()
            reassembler.clear()
            if subscribedCentrals.isEmpty {
                nextMessageId = UInt32.random(in: 1..<UInt32.max)
                status = DeviceStatus(connectionState: .connecting, statusLabel: "BLE glasses unsubscribed. Advertising again.")
                startAdvertising()
            } else {
                status = DeviceStatus(
                    connectionState: .connected,
                    statusLabel: "BLE inverted link ready. Rokid glasses subscribed to iPhone.",
                    bluetoothClientCount: subscribedCentrals.count
                )
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        Task { @MainActor in
            var result: CBATTError.Code = .success
            for request in requests {
                guard request.characteristic.uuid == rxUUID else {
                    result = .attributeNotFound
                    continue
                }
                guard let value = request.value else {
                    result = .invalidAttributeValueLength
                    continue
                }
                handleIncoming(value)
            }
            if let first = requests.first {
                peripheral.respond(to: first, withResult: result)
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            pumpNotifyQueue()
        }
    }
}
