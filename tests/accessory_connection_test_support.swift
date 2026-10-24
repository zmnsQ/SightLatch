import Foundation

// CoreBluetooth doubles exercise the production selected-transport delegate.
// They do not model Bluetooth encryption, bonding, or iOS HID ownership.
enum CBManagerState: Int { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
enum CBPeripheralState: Int { case disconnected, connecting, connected, disconnecting }
enum CBManagerAuthorization: Int { case notDetermined, restricted, denied, allowedAlways }
let CBCentralManagerOptionShowPowerAlertKey = "ShowPowerAlert"
let CBErrorDomain = "CBErrorDomain"
enum CBError: Int { case peerRemovedPairingInformation = 14 }
protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
}
@MainActor final class CBPeripheral: NSObject {
    let identifier: UUID
    var state = CBPeripheralState.disconnected
    init(identifier: UUID) { self.identifier = identifier }
}
@MainActor final class CBCentralManager: NSObject {
    static var authorization = CBManagerAuthorization.allowedAlways
    static var latest: CBCentralManager!
    weak var delegate: (any CBCentralManagerDelegate)?
    var state = CBManagerState.unknown
    var available: [CBPeripheral] = []
    var retrieved: [[UUID]] = []
    var connections: [UUID] = []
    var cancellations: [UUID] = []
    init(delegate: CBCentralManagerDelegate, queue: DispatchQueue?, options: [String: Any]?) {
        self.delegate = delegate
        super.init()
        Self.latest = self
    }
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        retrieved.append(identifiers)
        return available
    }
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        connections.append(peripheral.identifier)
        peripheral.state = .connecting
    }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        cancellations.append(peripheral.identifier)
        peripheral.state = .disconnected
    }
}
