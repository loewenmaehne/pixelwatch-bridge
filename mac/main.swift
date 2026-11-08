// Pixel Watch Bridge, Mac side.
//
// Talks to the real watch through the Mac's built-in Bluetooth:
//   le-scan [seconds] [--google]     list BLE advertisements (Google ones only with --google)
//   watch-scan [seconds]             wait for a watch in setup mode (the app's scan filter)
//                                    and print its advertisement for fake_watch.py
//   inquiry [seconds] [--le|--both]  device inquiry, classic Bluetooth by default
//   paired                           list devices paired with this Mac
//   sdp <address>                    list SDP services of a device
//   pair <address>                   pair (numeric comparison is confirmed, the code is printed)
//   unpair <address>                 remove the pairing from this Mac
//   bridge <address> <port>          relay the watch's Wear OS RFCOMM service to TCP clients on
//                                    127.0.0.1:<port>. Each client gets its own RFCOMM session;
//                                    pairing and the SDP lookup happen when the first one connects.
//
// Built as an app bundle (see build.sh) so macOS asks for Bluetooth permission
// for this tool only.

import CoreBluetooth
import Foundation
import IOBluetooth
import Network
import ObjectiveC

setvbuf(stdout, nil, _IOLBF, 0)

let wearServiceUUIDBytes: [UInt8] = [
    0x5E, 0x89, 0x45, 0xB0, 0x95, 0x25, 0x11, 0xE3,
    0xA5, 0xE2, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
]

let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

func log(_ message: String) {
    print("\(timestampFormatter.string(from: Date())) \(message)")
}

func hex(_ data: Data, limit: Int = 64) -> String {
    data.prefix(limit).map { String(format: "%02x", $0) }.joined()
}

func runLoop(timeout: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

func device(for address: String) -> IOBluetoothDevice? {
    IOBluetoothDevice(addressString: address.replacingOccurrences(of: ":", with: "-"))
}

func wearServiceUUID() -> IOBluetoothSDPUUID {
    wearServiceUUIDBytes.withUnsafeBytes { buffer in
        IOBluetoothSDPUUID(bytes: buffer.baseAddress, length: 16)
    }
}

func describe(_ record: IOBluetoothSDPServiceRecord) -> String {
    var channel: BluetoothRFCOMMChannelID = 0
    let rfcomm = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess ? "\(channel)" : "-"
    var classes: [String] = []
    if let list = record.getAttributeDataElement(0x0001),
        let elements = list.getArrayValue() as? [IOBluetoothSDPDataElement]
    {
        for element in elements {
            if let uuid = element.getUUIDValue() {
                classes.append(hex(Data(bytes: uuid.bytes, count: Int(uuid.length))))
            }
        }
    }
    return "name=\(record.getServiceName() ?? "-") rfcomm=\(rfcomm) classes=\(classes)"
}

func describeValue(_ value: Any) -> String {
    switch value {
    case let data as Data: return hex(data, limit: 256)
    case let uuids as [CBUUID]: return uuids.map(\.uuidString).joined(separator: ",")
    case let serviceData as [CBUUID: Data]:
        return serviceData.map { "\($0.key.uuidString)=\(hex($0.value))" }.joined(separator: ",")
    default: return String(describing: value)
    }
}

// The scan filter of the Pixel Watch app during setup, applied to the
// manufacturer data including the company id: Google (0x00E0), then data
// byte 1 is 0x13 or 0x14 and data byte 6 is 0x80 or 0x81.
func isWatchInSetup(_ manufacturer: [UInt8]) -> Bool {
    guard manufacturer.count >= 9, manufacturer[0] == 0xE0, manufacturer[1] == 0x00 else {
        return false
    }
    return [0x13, 0x14].contains(manufacturer[3]) && [0x80, 0x81].contains(manufacturer[8])
}

// CoreBluetooth hides device addresses. Lists getters and instance variables
// with "address" in their name, in case private API still exposes one.
func addressHints(_ object: NSObject) -> [String] {
    var hints: [String] = []
    var current: AnyClass? = object_getClass(object)
    while let cls = current, cls != NSObject.self {
        let className = NSStringFromClass(cls)
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            for index in 0..<Int(methodCount) {
                let method = methods[index]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                guard name.lowercased().contains("address") else { continue }
                let returnType = method_copyReturnType(method)
                let type = String(cString: returnType)
                free(returnType)
                if method_getNumberOfArguments(method) == 2 && type == "@" {
                    let value = object.perform(selector)?.takeUnretainedValue()
                    hints.append("\(className).\(name) = \(value.map { describeValue($0) } ?? "nil")")
                } else {
                    hints.append("\(className).\(name) type=\(type)")
                }
            }
            free(methods)
        }
        var ivarCount: UInt32 = 0
        if let ivars = class_copyIvarList(cls, &ivarCount) {
            for index in 0..<Int(ivarCount) {
                let ivar = ivars[index]
                guard let cName = ivar_getName(ivar) else { continue }
                let name = String(cString: cName)
                guard name.lowercased().contains("address") else { continue }
                let type = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?"
                if type.hasPrefix("@") {
                    let value = object_getIvar(object, ivar)
                    hints.append("\(className).\(name) = \(value.map { describeValue($0) } ?? "nil")")
                } else {
                    hints.append("\(className).\(name) type=\(type)")
                }
            }
            free(ivars)
        }
        current = class_getSuperclass(cls)
    }
    return hints
}

// MARK: - BLE scan

final class LEScanner: NSObject, CBCentralManagerDelegate {
    enum Mode { case all, google, watch }

    private var central: CBCentralManager!
    private let mode: Mode
    private var seen = Set<String>()
    private(set) var firstWatch: Date?

    init(mode: Mode) {
        self.mode = mode
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("le: state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
        guard central.state == .poweredOn else { return }
        // In watch mode duplicates are needed to catch the scan response (name).
        let options = mode == .watch ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil
        central.scanForPeripherals(withServices: nil, options: options)
        log("le: scanning")
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let manufacturer =
            (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
        let company = manufacturer.count >= 2 ? Int(manufacturer[0]) | Int(manufacturer[1]) << 8 : -1
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-"

        if mode == .watch {
            guard isWatchInSetup(manufacturer) else { return }
            let key = "\(peripheral.identifier) \(name) \(hex(Data(manufacturer)))"
            guard seen.insert(key).inserted else { return }
            if firstWatch == nil { firstWatch = Date() }
            log("watch: \(peripheral.identifier) rssi=\(RSSI) name=\(name)")
            log("watch: payload \(hex(Data(manufacturer.dropFirst(2))))")
            for (key, value) in advertisementData.sorted(by: { $0.key < $1.key }) {
                log("watch: adv \(key) = \(describeValue(value))")
            }
            for hint in addressHints(peripheral) { log("watch: hint \(hint)") }
            return
        }

        if mode == .google && company != 0x00E0 { return }
        guard seen.insert(peripheral.identifier.uuidString).inserted else { return }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        var line = "le: \(peripheral.identifier) rssi=\(RSSI) name=\(name) connectable=\(connectable)"
        if !manufacturer.isEmpty {
            line += String(format: " company=0x%04x", company) + " data=\(hex(Data(manufacturer)))"
        }
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            line += " services=\(services.map(\.uuidString))"
        }
        log(line)
    }
}

// MARK: - Inquiry

final class Inquiry: NSObject, IOBluetoothDeviceInquiryDelegate {
    private var inquiry: IOBluetoothDeviceInquiry!
    var done = false

    // searchType: 1 classic, 2 LE, 3 both (IOBluetoothDeviceSearchTypes)
    func start(seconds: Int, searchType: UInt32) {
        inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry.inquiryLength = UInt8(min(max(seconds, 1), 60))
        inquiry.updateNewDeviceNames = true
        inquiry.searchType = searchType
        log("inquiry: start type=\(searchType) result=\(inquiry.start())")
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        log(
            "inquiry: found \(device.addressString ?? "?") name=\(device.name ?? "-") "
                + String(format: "class=0x%06x", device.classOfDevice) + " rssi=\(device.rawRSSI())"
        )
    }

    func deviceInquiryDeviceNameUpdated(
        _ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32
    ) {
        log("inquiry: name \(device.addressString ?? "?") = \(device.name ?? "-")")
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        log("inquiry: complete error=\(error) aborted=\(aborted)")
        done = true
    }
}

// MARK: - SDP

final class SDPQuery: NSObject {
    private let device: IOBluetoothDevice
    private let onComplete: (IOReturn) -> Void

    init(device: IOBluetoothDevice, onComplete: @escaping (IOReturn) -> Void) {
        self.device = device
        self.onComplete = onComplete
    }

    func start() -> IOReturn { device.performSDPQuery(self) }

    // Asks the device for these services; the plain query may only return
    // what macOS cached at pairing time, without custom services.
    func start(uuids: [IOBluetoothSDPUUID]) -> IOReturn { device.performSDPQuery(self, uuids: uuids) }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let onComplete = onComplete
        DispatchQueue.main.async { onComplete(status) }  // the owner may release us
    }
}

// MARK: - SDP link
//
// macOS answers IOBluetooth SDP queries from its cache, which holds only the
// profiles it searched for at pairing time (Handsfree, A2DP, AVRCP), not the
// Wear OS service. So the bridge asks the watch's SDP server itself over
// L2CAP PSM 1: a ServiceSearchAttribute request for the Wear OS UUID, reading
// the RFCOMM channel from the ProtocolDescriptorList. The open channel also
// holds the link to the watch, and the query repeats every second until the
// service shows up (the watch publishes it a few seconds after pairing).

func rfcommChannel(in bytes: [UInt8]) -> BluetoothRFCOMMChannelID? {
    guard bytes.count >= 5 else { return nil }
    // ... 19 00 03 08 <channel>: UUID16 RFCOMM followed by a uint8 channel
    for index in 0...(bytes.count - 5)
    where bytes[index] == 0x19 && bytes[index + 1] == 0x00 && bytes[index + 2] == 0x03
        && bytes[index + 3] == 0x08
    {
        return bytes[index + 4]
    }
    return nil
}

final class SDPLink: NSObject, IOBluetoothL2CAPChannelDelegate {
    private let device: IOBluetoothDevice
    var onChannel: ((BluetoothRFCOMMChannelID) -> Void)?
    var onClosed: (() -> Void)?
    private var channel: IOBluetoothL2CAPChannel?
    private var transaction: UInt16 = 0
    private var stopped = false
    private var found = false

    init(device: IOBluetoothDevice) { self.device = device }

    func open() -> IOReturn {
        var opened: IOBluetoothL2CAPChannel?
        let result = device.openL2CAPChannelAsync(&opened, withPSM: 0x0001, delegate: self)
        channel = opened
        log("sdplink: opening L2CAP to the watch's SDP server result=\(result)")
        return result
    }

    func close() {
        guard !stopped else { return }
        stopped = true
        log("sdplink: closing")
        if let channel {
            self.channel = nil
            channel.setDelegate(nil)
            channel.close()
        }
    }

    func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        guard !stopped else { return }
        guard error == kIOReturnSuccess else {
            log("sdplink: open failed \(error)")
            channel = nil
            notifyClosed()
            return
        }
        log("sdplink: open, paired=\(device.isPaired())")
        query()
    }

    private func query() {
        guard !stopped, let channel else { return }
        transaction &+= 1
        let pattern: [UInt8] = [0x35, 0x11, 0x1C] + wearServiceUUIDBytes
        let attributes: [UInt8] = [0x35, 0x03, 0x09, 0x00, 0x04]  // ProtocolDescriptorList
        let parameters = pattern + [0x04, 0x00] + attributes + [0x00]
        var pdu: [UInt8] = [
            0x06, UInt8(transaction >> 8), UInt8(transaction & 0xFF),
            UInt8(parameters.count >> 8), UInt8(parameters.count & 0xFF),
        ]
        pdu += parameters
        let result = pdu.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
        }
        if result != kIOReturnSuccess { log("sdplink: request failed \(result)") }
    }

    func l2capChannelData(
        _ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard !stopped else { return }
        let bytes = [UInt8](Data(bytes: dataPointer, count: dataLength))
        if let id = rfcommChannel(in: bytes) {
            if !found {
                found = true
                log("sdplink: Wear OS service on RFCOMM channel \(id) (query \(transaction))")
                onChannel?(id)
            }
            // The watch closes an idle SDP connection after 30 s and then the
            // link drops; asking again every 10 s keeps it until RFCOMM opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.query() }
            return
        }
        if transaction == 1 || transaction % 10 == 0 {
            log("sdplink: Wear OS service not published yet (query \(transaction), \(hex(Data(bytes), limit: 24)))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.query() }
    }

    func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        guard !stopped else { return }
        log("sdplink: closed")
        channel = nil
        notifyClosed()
    }

    private func notifyClosed() {
        stopped = true
        let onClosed = onClosed
        DispatchQueue.main.async { onClosed?() }  // the owner may release us
    }
}

// MARK: - Pairing

final class Pairing: NSObject, IOBluetoothDevicePairDelegate {
    private var pair: IOBluetoothDevicePair?
    private let onFinish: (Bool) -> Void

    init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

    func start(device: IOBluetoothDevice) -> IOReturn {
        let pair = IOBluetoothDevicePair(device: device)
        pair?.delegate = self
        self.pair = pair
        return pair?.start() ?? kIOReturnError
    }

    func devicePairingStarted(_ sender: Any!) { log("pair: started") }
    func devicePairingConnecting(_ sender: Any!) { log("pair: connecting") }
    func devicePairingConnected(_ sender: Any!) { log("pair: connected") }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        log(String(format: "pair: code %06u, confirming", numericValue))
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        log(String(format: "pair: passkey %06u", passkey))
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        log("pair: legacy PIN requested, not supported")
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        log("pair: finished error=\(error)")
        let onFinish = onFinish
        let succeeded = error == kIOReturnSuccess
        DispatchQueue.main.async { onFinish(succeeded) }  // the owner may release us
    }
}

// MARK: - Bridge

final class Bridge: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let device: IOBluetoothDevice
    private let port: UInt16
    private var listener: NWListener?
    private var client: NWConnection?
    private var session = 0
    private var pending = Data()  // phone -> watch, until the RFCOMM channel is open
    private var channel: IOBluetoothRFCOMMChannel?
    private var channelOpen = false
    private var channelID: BluetoothRFCOMMChannelID = 0
    private var sdpLink: SDPLink?
    private var notifications: [IOBluetoothUserNotification] = []
    var failed = false

    init(device: IOBluetoothDevice, port: UInt16) {
        self.device = device
        self.port = port
    }

    func useChannel(_ channel: BluetoothRFCOMMChannelID) {
        channelID = channel
        log("bridge: using RFCOMM channel \(channel) as given")
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port),
            let listener = try? NWListener(using: parameters, on: nwPort)
        else {
            log("bridge: cannot listen on port \(port)")
            failed = true
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in log("bridge: listener \(state)") }
        listener.start(queue: .main)
        self.listener = listener
        watchLinkEvents()
        log("bridge: watch paired=\(device.isPaired()), waiting for the relay on port \(port)")
        holdWatch()
    }

    // MARK: Sessions

    private func accept(_ connection: NWConnection) {
        if client != nil { endSession("a new relay connection replaces it") }
        session += 1
        client = connection
        log("bridge: session \(session) starts")
        connection.start(queue: .main)
        receive(from: connection, session: session)
        connectWatch()
    }

    private func endSession(_ reason: String) {
        log("bridge: session \(session) ends: \(reason)")
        if let channel {
            self.channel = nil
            channel.setDelegate(nil)
            channel.close()
        }
        channelOpen = false
        pending.removeAll()
        client?.cancel()
        client = nil
        holdWatch()
    }

    private func receive(from connection: NWConnection, session id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self, id == self.session, self.client != nil else { return }
            if let data, !data.isEmpty {
                log("bridge: phone -> watch \(data.count) bytes \(hex(data, limit: 24))")
                self.writeToWatch(data)
            }
            if isComplete || error != nil {
                self.endSession("the relay closed (\(error.map { "\($0)" } ?? "eof"))")
                return
            }
            self.receive(from: connection, session: id)
        }
    }

    // MARK: Watch side
    //
    // In setup mode the watch takes new connections only until it is paired
    // and publishes the Wear OS service a few seconds after pairing. A phone
    // keeps the link from pairing and connects over it, and so does the
    // bridge: the SDP link is opened while the watch is still unpaired, macOS
    // then pairs on its own and shows its dialog (apps cannot confirm pairing
    // themselves, IOBluetoothDevicePair times out), the link stays open and
    // asks for the service every second, and the RFCOMM channel is opened over
    // the same link once the service appears and a phone session is waiting.

    private var watchReady: Bool { channelID != 0 && device.isPaired() }

    private func holdWatch() {
        guard sdpLink == nil, channel == nil else { return }
        let link = SDPLink(device: device)
        link.onChannel = { [weak self] id in
            guard let self else { return }
            self.channelID = id
            log("bridge: ready, paired=\(self.device.isPaired()), session waiting=\(self.client != nil)")
            self.connectWatch()
        }
        link.onClosed = { [weak self] in
            guard let self else { return }
            self.sdpLink = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.holdWatch() }
        }
        guard link.open() == kIOReturnSuccess else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.holdWatch() }
            return
        }
        sdpLink = link
    }

    private func connectWatch() {
        guard client != nil, channel == nil else { return }
        guard watchReady else {
            holdWatch()
            return
        }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        log("bridge: opening RFCOMM channel \(channelID) result=\(result)")
        guard result == kIOReturnSuccess, let opened else {
            endSession("RFCOMM open did not start")
            return
        }
        channel = opened
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard rfcommChannel === channel else { return }
        log("bridge: RFCOMM open status=\(error) mtu=\(rfcommChannel.getMTU())")
        guard error == kIOReturnSuccess else {
            channel = nil
            endSession("RFCOMM open failed")
            return
        }
        channelOpen = true
        sdpLink?.close()  // the RFCOMM channel holds the link now
        sdpLink = nil
        if !pending.isEmpty {
            let data = pending
            pending.removeAll()
            writeToWatch(data)
        }
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard rfcommChannel === channel else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        log("bridge: watch -> phone \(data.count) bytes \(hex(data, limit: 24))")
        client?.send(content: data, completion: .contentProcessed { _ in })
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        channel = nil
        channelOpen = false
        endSession("the watch closed the RFCOMM channel")
    }

    private func writeToWatch(_ data: Data) {
        guard let channel, channelOpen else {
            pending.append(data)
            return
        }
        let mtu = max(Int(channel.getMTU()), 1)
        var offset = 0
        while offset < data.count {
            var chunk = data.subdata(in: offset..<min(offset + mtu, data.count))
            let result = chunk.withUnsafeMutableBytes { buffer in
                channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
            }
            if result != kIOReturnSuccess { log("bridge: write to the watch failed \(result)") }
            offset += mtu
        }
    }

    // MARK: Link events of the watch (diagnostics)

    private func isWatch(_ other: IOBluetoothDevice?) -> Bool {
        guard let other, let address = other.addressString else { return false }
        return address.lowercased() == device.addressString?.lowercased()
    }

    private func watchLinkEvents() {
        let registrations = [
            IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(linkUp(_:device:))),
            IOBluetoothL2CAPChannel.register(
                forChannelOpenNotifications: self, selector: #selector(l2capOpened(_:channel:))),
            IOBluetoothRFCOMMChannel.register(
                forChannelOpenNotifications: self, selector: #selector(rfcommOpened(_:channel:))),
        ]
        notifications.append(contentsOf: registrations.compactMap { $0 })
    }

    @objc func linkUp(_ notification: IOBluetoothUserNotification, device other: IOBluetoothDevice) {
        guard isWatch(other) else { return }
        log("link: connected")
        if let registration = other.register(
            forDisconnectNotification: self, selector: #selector(linkDown(_:device:)))
        {
            notifications.append(registration)
        }
    }

    @objc func linkDown(_ notification: IOBluetoothUserNotification, device other: IOBluetoothDevice) {
        guard isWatch(other) else { return }
        log("link: disconnected")
    }

    @objc func l2capOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        guard isWatch(channel.device) else { return }
        log("link: L2CAP psm=\(channel.psm) incoming=\(channel.isIncoming())")
    }

    @objc func rfcommOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        guard isWatch(channel.getDevice()) else { return }
        log("link: RFCOMM channel \(channel.getID()) incoming=\(channel.isIncoming())")
    }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

// Give `open -W` time to attach before a quick command exits.
Thread.sleep(forTimeInterval: 0.5)

switch command {
case "le-scan":
    let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 15
    let scanner = LEScanner(mode: arguments.contains("--google") ? .google : .all)
    runLoop(timeout: seconds)
    withExtendedLifetime(scanner) { log("le: done") }

case "watch-scan":
    let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 60
    let scanner = LEScanner(mode: .watch)
    // Keep scanning a few seconds after the first hit to catch the scan response.
    runLoop(timeout: seconds) { scanner.firstWatch.map { Date().timeIntervalSince($0) > 5 } ?? false }
    log(scanner.firstWatch == nil ? "watch: none found" : "watch: done")
    exit(scanner.firstWatch == nil ? 1 : 0)

case "inquiry":
    let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 15
    let searchType: UInt32 = arguments.contains("--both") ? 3 : arguments.contains("--le") ? 2 : 1
    let inquiry = Inquiry()
    inquiry.start(seconds: seconds, searchType: searchType)
    runLoop(timeout: Double(seconds) + 10) { inquiry.done }

case "paired":
    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    log("paired: \(devices.count) devices")
    for device in devices {
        log(
            "paired: \(device.addressString ?? "?") name=\(device.name ?? "-") "
                + "connected=\(device.isConnected())"
        )
    }

case "sdp":
    guard arguments.count >= 2, let target = device(for: arguments[1]) else {
        log("usage: sdp <address>")
        exit(2)
    }
    var finished = false
    let query = SDPQuery(device: target) { status in
        log("sdp: complete status=\(status)")
        for record in (target.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            log("sdp: service \(describe(record))")
        }
        finished = true
    }
    log("sdp: query result=\(query.start())")
    runLoop(timeout: 30) { finished }

case "pair":
    guard arguments.count >= 2, let target = device(for: arguments[1]) else {
        log("usage: pair <address>")
        exit(2)
    }
    var outcome: Bool?
    let pairing = Pairing { succeeded in outcome = succeeded }
    log("pair: start result=\(pairing.start(device: target))")
    runLoop(timeout: 90) { outcome != nil }
    exit(outcome == true ? 0 : 1)

case "sdp-raw":
    guard arguments.count >= 2, let target = device(for: arguments[1]) else {
        log("usage: sdp-raw <address>")
        exit(2)
    }
    var done = false
    let link = SDPLink(device: target)
    link.onChannel = { _ in done = true }
    link.onClosed = { done = true }
    _ = link.open()
    runLoop(timeout: 30) { done }
    link.close()

case "services":
    // What macOS has cached for the device, without asking it again.
    guard arguments.count >= 2, let target = device(for: arguments[1]) else {
        log("usage: services <address>")
        exit(2)
    }
    let records = (target.services as? [IOBluetoothSDPServiceRecord]) ?? []
    log("services: \(records.count) cached, paired=\(target.isPaired())")
    records.forEach { log("services: \(describe($0))") }

case "unpair":
    // Private IOBluetooth API (also used by blueutil). Needed when the watch
    // went back to setup and forgot the pairing while the Mac kept it.
    guard arguments.count >= 2, let target = device(for: arguments[1]) else {
        log("usage: unpair <address>")
        exit(2)
    }
    let remove = Selector(("remove"))
    guard target.responds(to: remove) else {
        log("unpair: not supported on this macOS")
        exit(1)
    }
    target.perform(remove)
    runLoop(timeout: 2)
    log("unpair: done, paired=\(target.isPaired())")

case "bridge":
    guard arguments.count >= 3, let target = device(for: arguments[1]),
        let port = UInt16(arguments[2])
    else {
        log("usage: bridge <address> <port>")
        exit(2)
    }
    let bridge = Bridge(device: target, port: port)
    // Optional fourth argument: the watch's RFCOMM channel, if SDP cannot find it.
    if arguments.count >= 4, let channel = UInt8(arguments[3]) { bridge.useChannel(channel) }
    bridge.start()
    runLoop(timeout: 86_400 * 365) { bridge.failed }

default:
    print(
        """
        usage: PixelWatchBridge le-scan [seconds] [--google] | watch-scan [seconds]
               | inquiry [seconds] [--le|--both] | paired | sdp <address> | pair <address>
               | unpair <address> | bridge <address> <port>
        """)
}
