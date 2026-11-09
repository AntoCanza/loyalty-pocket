import CoreBluetooth
import CoreFoundation
import Flutter
import Foundation
import Security
import UIKit

final class LoyaltyBluetoothSync: NSObject {
  private static let serviceID = CBUUID(string: "3bf9aa04-1c0d-43b6-95a0-82efcf4dd9a9")
  private static let writeID = CBUUID(string: "3bf9aa04-1c0d-43b6-95a0-82efcf4dd9aa")
  private static let indicateID = CBUUID(string: "3bf9aa04-1c0d-43b6-95a0-82efcf4dd9ab")
  private static let centralRestoreID = "loyalty-pocket.bluetooth.central"
  private static let peripheralRestoreID = "loyalty-pocket.bluetooth.peripheral"
  private static let maxLinks = 4
  private static let maxOutgoing = 2
  private static let maxPacket = 512
  private static let cooldown: TimeInterval = 8

  private enum Remote {
    case peripheral(CBPeripheral)
    case central(CBCentral)
  }

  private final class Link {
    let id: String
    let remote: Remote
    var writeCharacteristic: CBCharacteristic?
    var maxPacket = 0
    var announced = false
    var received: [Data] = []
    var connectionTimeout: DispatchWorkItem?
    var sendTimeout: DispatchWorkItem?
    var sendResult: FlutterResult?
    var pendingIndication: Data?

    init(id: String, remote: Remote) {
      self.id = id
      self.remote = remote
    }

    var isOutgoing: Bool {
      if case .peripheral = remote { return true }
      return false
    }
  }

  private let channel: FlutterMethodChannel
  private var centralManager: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?
  private var localService: CBMutableService?
  private var indicateCharacteristic: CBMutableCharacteristic?
  private var serviceReady = false
  private var advertisingPending = false
  private var enabled = false
  private var dartAttached = false
  private var lastStatus: String?
  private var startResult: FlutterResult?
  private var startTimeout: DispatchWorkItem?
  private var links: [String: Link] = [:]
  private var cooldowns: [String: Date] = [:]
  private var scanRetry: DispatchWorkItem?
  private var scanRetryAt: Date?
  private var restoredPeripherals: [CBPeripheral] = []

  init(messenger: FlutterBinaryMessenger, launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    channel = FlutterMethodChannel(name: "loyalty_pocket/bluetooth_sync", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "bluetooth_unavailable", message: nil, details: nil))
        return
      }
      self.handle(call, result: result)
    }
    let restoringCentral = (launchOptions?[.bluetoothCentrals] as? [String])?
      .contains(Self.centralRestoreID) == true
    let restoringPeripheral = (launchOptions?[.bluetoothPeripherals] as? [String])?
      .contains(Self.peripheralRestoreID) == true
    if (restoringCentral || restoringPeripheral), storedGroupKey().data?.count == 32 {
      enabled = true
      createManagers()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "start":
      guard let prompt = arguments?["prompt"] as? NSNumber,
            CFGetTypeID(prompt) == CFBooleanGetTypeID() else {
        result(Self.invalidArgument)
        return
      }
      start(prompt: prompt.boolValue, result: result)
    case "stop":
      stop()
      result(nil)
    case "send":
      guard let id = arguments?["id"] as? String,
            let bytes = arguments?["bytes"] as? FlutterStandardTypedData else {
        result(Self.invalidArgument)
        return
      }
      send(id: id, bytes: bytes.data, result: result)
    case "disconnect":
      guard let id = arguments?["id"] as? String else {
        result(Self.invalidArgument)
        return
      }
      if let link = links[id] { drop(link) }
      result(nil)
    case "readGroupKey":
      readGroupKey(result)
    case "writeGroupKey":
      writeGroupKey(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static var invalidArgument: FlutterError {
    FlutterError(code: "invalid_argument", message: "Invalid Bluetooth sync argument.", details: nil)
  }

  private static var disconnected: FlutterError {
    FlutterError(code: "bluetooth_disconnected", message: nil, details: nil)
  }

  private var authorization: CBManagerAuthorization {
    if #available(iOS 13.1, *) { return CBManager.authorization }
    return centralManager?.authorization ?? peripheralManager?.authorization ?? .notDetermined
  }

  private func start(prompt: Bool, result: @escaping FlutterResult) {
    let permission = authorization
    guard permission != .denied, permission != .restricted,
          prompt || permission != .notDetermined else {
      result("permissionDenied")
      return
    }
    let newlyAttached = !dartAttached
    dartAttached = true
    enabled = true
    finishStart("unavailable")
    startResult = result
    let timeout = DispatchWorkItem { [weak self] in self?.finishStart("unavailable") }
    startTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    createManagers()
    ensureScan()
    ensureAdvertising()
    publishStatus()
    if newlyAttached {
      for link in links.values { announce(link) }
    }
  }

  private func createManagers() {
    if centralManager == nil {
      centralManager = CBCentralManager(delegate: self, queue: nil, options: [
        CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID,
        CBCentralManagerOptionShowPowerAlertKey: false,
      ])
    }
    if peripheralManager == nil {
      peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: [
        CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreID,
        CBPeripheralManagerOptionShowPowerAlertKey: false,
      ])
    }
  }

  private func finishStart(_ status: String) {
    startTimeout?.cancel()
    startTimeout = nil
    let result = startResult
    startResult = nil
    result?(status)
  }

  private func publishStatus() {
    guard enabled else { return }
    let states = [centralManager?.state, peripheralManager?.state].compactMap { $0 }
    let status: String
    if authorization == .denied || authorization == .restricted || states.contains(.unauthorized) {
      status = "permissionDenied"
    } else if !states.isEmpty && states.allSatisfy({ $0 == .unsupported }) {
      status = "unavailable"
    } else if authorization == .notDetermined {
      return
    } else if states.contains(.poweredOn) {
      status = "ready"
    } else if states.contains(.poweredOff) {
      status = "bluetoothOff"
    } else if states.contains(.unknown) || states.contains(.resetting) || states.isEmpty {
      return
    } else {
      status = "unavailable"
    }
    finishStart(status)
    if dartAttached && lastStatus != status {
      lastStatus = status
      channel.invokeMethod("status", arguments: status)
    }
  }

  private func stop() {
    enabled = false
    finishStart("unavailable")
    cancelScanRetry()
    if centralManager?.isScanning == true { centralManager?.stopScan() }
    for link in Array(links.values) { drop(link, coolDown: false) }
    if peripheralManager?.state == .poweredOn {
      peripheralManager?.stopAdvertising()
      peripheralManager?.removeAllServices()
    }
    clearLocalService()
    restoredPeripherals.removeAll()
    cooldowns.removeAll()
    dartAttached = false
    lastStatus = nil
  }

  private func ensureScan(restart: Bool = false) {
    guard enabled, let central = centralManager, central.state == .poweredOn else { return }
    let canScan = links.count < Self.maxLinks && links.values.filter { $0.isOutgoing }.count < Self.maxOutgoing
    if central.isScanning && (restart || !canScan) { central.stopScan() }
    if canScan && !central.isScanning {
      central.scanForPeripherals(withServices: [Self.serviceID], options: nil)
    }
  }

  private func retryScan(after delay: TimeInterval) {
    guard enabled else { return }
    let date = Date().addingTimeInterval(delay)
    if let scanRetryAt, scanRetryAt <= date { return }
    cancelScanRetry()
    let work = DispatchWorkItem { [weak self] in
      self?.scanRetry = nil
      self?.scanRetryAt = nil
      self?.ensureScan(restart: true)
    }
    scanRetry = work
    scanRetryAt = date
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func cancelScanRetry() {
    scanRetry?.cancel()
    scanRetry = nil
    scanRetryAt = nil
  }

  private func ensureAdvertising() {
    guard enabled, let manager = peripheralManager, manager.state == .poweredOn else { return }
    if localService == nil {
      let writable = CBMutableCharacteristic(
        type: Self.writeID, properties: .write, value: nil, permissions: .writeable)
      let indications = CBMutableCharacteristic(
        type: Self.indicateID, properties: .indicate, value: nil, permissions: [])
      let service = CBMutableService(type: Self.serviceID, primary: true)
      service.characteristics = [writable, indications]
      localService = service
      indicateCharacteristic = indications
      manager.add(service)
    } else if serviceReady && !manager.isAdvertising && !advertisingPending {
      advertisingPending = true
      manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
    }
  }

  private func clearLocalService() {
    localService = nil
    indicateCharacteristic = nil
    serviceReady = false
    advertisingPending = false
  }

  private func outgoingID(_ identifier: UUID) -> String { "central:\(identifier.uuidString)" }
  private func incomingID(_ identifier: UUID) -> String { "peripheral:\(identifier.uuidString)" }

  private func beginConnection(_ peripheral: CBPeripheral) {
    let link = Link(id: outgoingID(peripheral.identifier), remote: .peripheral(peripheral))
    links[link.id] = link
    peripheral.delegate = self
    let timeout = DispatchWorkItem { [weak self, weak link] in
      if let link { self?.drop(link) }
    }
    link.connectionTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
  }

  private func ready(_ link: Link, maxPacket: Int) {
    guard link.maxPacket == 0 else { return }
    guard maxPacket > 0 else { drop(link); return }
    link.connectionTimeout?.cancel()
    link.connectionTimeout = nil
    link.maxPacket = min(Self.maxPacket, maxPacket)
    announce(link)
  }

  private func announce(_ link: Link) {
    guard dartAttached, !link.announced, link.maxPacket > 0 else { return }
    link.announced = true
    channel.invokeMethod("peerConnected", arguments: [
      "id": link.id, "central": link.isOutgoing, "maxPacketBytes": link.maxPacket,
    ])
    for bytes in link.received { emit(bytes, from: link) }
    link.received.removeAll()
  }

  private func emit(_ bytes: Data, from link: Link) {
    channel.invokeMethod("bytesReceived", arguments: [
      "id": link.id, "bytes": FlutterStandardTypedData(bytes: bytes),
    ])
  }

  private func receive(_ bytes: Data, from link: Link) -> Bool {
    guard !bytes.isEmpty, bytes.count <= Self.maxPacket else { return false }
    if link.announced {
      emit(bytes, from: link)
    } else {
      guard link.received.count < 16 else { return false }
      link.received.append(bytes)
    }
    return true
  }

  private func drop(_ link: Link, coolDown: Bool = true, cancelConnection: Bool = true) {
    guard links[link.id] === link else { return }
    links.removeValue(forKey: link.id)
    link.connectionTimeout?.cancel()
    finishSend(link, error: Self.disconnected)
    if link.announced { channel.invokeMethod("peerDisconnected", arguments: ["id": link.id]) }
    if coolDown {
      let now = Date()
      cooldowns = cooldowns.filter { $0.value > now }
      if cooldowns.count >= 64, let oldest = cooldowns.min(by: { $0.value < $1.value })?.key {
        cooldowns.removeValue(forKey: oldest)
      }
      cooldowns[link.id] = now.addingTimeInterval(Self.cooldown)
    }
    if case .peripheral(let peripheral) = link.remote, cancelConnection,
       centralManager?.state == .poweredOn {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    ensureScan()
    if coolDown { retryScan(after: Self.cooldown) }
  }

  private func send(id: String, bytes: Data, result: @escaping FlutterResult) {
    guard let link = links[id], link.announced else { result(Self.disconnected); return }
    guard !bytes.isEmpty, bytes.count <= link.maxPacket else { result(Self.invalidArgument); return }
    guard link.sendResult == nil else {
      result(FlutterError(code: "bluetooth_busy", message: nil, details: nil))
      return
    }
    let timeout = DispatchWorkItem { [weak self, weak link] in
      if let link { self?.drop(link) }
    }
    link.sendResult = result
    link.sendTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    switch link.remote {
    case .peripheral(let remote):
      guard remote.state == .connected, let characteristic = link.writeCharacteristic else {
        drop(link)
        return
      }
      remote.writeValue(bytes, for: characteristic, type: .withResponse)
    case .central:
      link.pendingIndication = bytes
      sendIndication(for: link)
    }
  }

  private func sendIndication(for link: Link) {
    guard let bytes = link.pendingIndication,
          case .central(let central) = link.remote else { return }
    guard let manager = peripheralManager, manager.state == .poweredOn,
          let characteristic = indicateCharacteristic else { drop(link); return }
    if manager.updateValue(bytes, for: characteristic, onSubscribedCentrals: [central]) {
      finishSend(link, error: nil)
    }
  }

  private func finishSend(_ link: Link, error: FlutterError?) {
    link.sendTimeout?.cancel()
    link.sendTimeout = nil
    link.pendingIndication = nil
    let result = link.sendResult
    link.sendResult = nil
    result?(error)
  }

  private var keyQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.antocanza.loyalty_pocket.bluetooth_sync",
      kSecAttrAccount as String: "group-key-v1",
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func storedGroupKey() -> (status: OSStatus, data: Data?) {
    var query = keyQuery
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    return (status, item as? Data)
  }

  private func readGroupKey(_ result: FlutterResult) {
    let (status, data) = storedGroupKey()
    if status == errSecItemNotFound {
      result(nil)
    } else if status == errSecSuccess, let bytes = data, bytes.count == 32 {
      result(FlutterStandardTypedData(bytes: bytes))
    } else {
      result(FlutterError(code: "keychain_read_failed", message: nil, details: Int(status)))
    }
  }

  private func writeGroupKey(_ arguments: Any?, result: FlutterResult) {
    if arguments == nil || arguments is NSNull {
      let status = SecItemDelete(keyQuery as CFDictionary)
      if status == errSecSuccess || status == errSecItemNotFound {
        result(nil)
      } else {
        result(FlutterError(code: "keychain_write_failed", message: nil, details: Int(status)))
      }
      return
    }
    guard let bytes = arguments as? FlutterStandardTypedData, bytes.data.count == 32 else {
      result(Self.invalidArgument)
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: bytes.data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(keyQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let item = keyQuery.merging(attributes) { _, value in value }
      status = SecItemAdd(item as CFDictionary, nil)
    }
    result(status == errSecSuccess ? nil : FlutterError(
      code: "keychain_write_failed", message: nil, details: Int(status)))
  }
}

extension LoyaltyBluetoothSync: CBCentralManagerDelegate, CBPeripheralDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      if !restoredPeripherals.isEmpty {
        for peripheral in restoredPeripherals
          where peripheral.state == .connected || peripheral.state == .connecting {
          // The encrypted Dart session was lost with the old process.
          central.cancelPeripheralConnection(peripheral)
        }
        restoredPeripherals.removeAll()
        retryScan(after: 1)
      }
      ensureScan()
    } else {
      for link in links.values.filter({ $0.isOutgoing }) { drop(link, coolDown: false) }
    }
    publishStatus()
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard enabled else { return }
    restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    let id = outgoingID(peripheral.identifier)
    guard enabled, links[id] == nil, links.count < Self.maxLinks,
          links.values.filter({ $0.isOutgoing }).count < Self.maxOutgoing else { return }
    if let delay = cooldowns[id]?.timeIntervalSinceNow, delay > 0 {
      retryScan(after: delay)
      return
    }
    if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool,
       !connectable { return }
    beginConnection(peripheral)
    central.connect(peripheral, options: nil)
    ensureScan()
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard enabled, links[outgoingID(peripheral.identifier)] != nil else {
      central.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverServices([Self.serviceID])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    if let link = links[outgoingID(peripheral.identifier)] { drop(link, cancelConnection: false) }
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    if let link = links[outgoingID(peripheral.identifier)] { drop(link, cancelConnection: false) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let link = links[outgoingID(peripheral.identifier)] else { return }
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
      drop(link)
      return
    }
    peripheral.discoverCharacteristics([Self.writeID, Self.indicateID], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard let link = links[outgoingID(peripheral.identifier)] else { return }
    guard error == nil,
          let write = service.characteristics?.first(where: { $0.uuid == Self.writeID }),
          write.properties.contains(.write),
          let indicate = service.characteristics?.first(where: { $0.uuid == Self.indicateID }),
          indicate.properties.contains(.indicate) else { drop(link); return }
    link.writeCharacteristic = write
    peripheral.setNotifyValue(true, for: indicate)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard characteristic.uuid == Self.indicateID,
          let link = links[outgoingID(peripheral.identifier)] else { return }
    guard error == nil, characteristic.isNotifying else { drop(link); return }
    // Using the no-response limit keeps writes to one ATT packet, even on platforms
    // where the with-response API can perform larger prepared writes.
    ready(link, maxPacket: min(
      peripheral.maximumWriteValueLength(for: .withResponse),
      peripheral.maximumWriteValueLength(for: .withoutResponse)))
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard characteristic.uuid == Self.indicateID,
          let link = links[outgoingID(peripheral.identifier)] else { return }
    guard error == nil, let bytes = characteristic.value, receive(bytes, from: link) else {
      drop(link)
      return
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard characteristic.uuid == Self.writeID,
          let link = links[outgoingID(peripheral.identifier)] else { return }
    if error == nil { finishSend(link, error: nil) } else { drop(link) }
  }
}

extension LoyaltyBluetoothSync: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    if peripheral.state == .poweredOn {
      ensureAdvertising()
    } else {
      for link in links.values.filter({ !$0.isOutgoing }) { drop(link, coolDown: false) }
      clearLocalService()
    }
    publishStatus()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    guard enabled,
          let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
          let service = services.first(where: { $0.uuid == Self.serviceID }),
          let indications = service.characteristics?.first(where: { $0.uuid == Self.indicateID })
            as? CBMutableCharacteristic else { return }
    localService = service
    indicateCharacteristic = indications
    serviceReady = true
    // Restored subscriptions belong to the previous Dart process. Accept new
    // subscriptions after rediscovery instead of resuming those sessions.
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    guard enabled, service.uuid == localService?.uuid else { return }
    if error == nil {
      serviceReady = true
      ensureAdvertising()
    } else {
      clearLocalService()
    }
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    advertisingPending = false
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
  ) {
    let id = incomingID(central.identifier)
    guard enabled, characteristic.uuid == Self.indicateID, links[id] == nil,
          links.count < Self.maxLinks, (cooldowns[id]?.timeIntervalSinceNow ?? 0) <= 0 else { return }
    let link = Link(id: id, remote: .central(central))
    links[id] = link
    ready(link, maxPacket: central.maximumUpdateValueLength)
    ensureScan()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == Self.indicateID, let link = links[incomingID(central.identifier)] else { return }
    drop(link)
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let request = requests.first else { return }
    guard requests.count == 1, request.characteristic.uuid == Self.writeID else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }
    guard request.offset == 0 else {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    guard let link = links[incomingID(request.central.identifier)],
          let bytes = request.value, receive(bytes, from: link) else {
      peripheral.respond(to: request, withResult: .unlikelyError)
      return
    }
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    for link in Array(links.values) { sendIndication(for: link) }
  }
}
