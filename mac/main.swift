// Pixel Watch Bridge, Mac side.
//
// Talks to the real watch through the Mac's built-in Bluetooth:
//   le-scan [seconds] [--google]   list BLE advertisements (Google ones only with --google)
//   inquiry [seconds]              classic Bluetooth inquiry (discoverable devices)
//   paired                         list devices paired with this Mac
//   sdp <address>                  list SDP services of a device
//   pair <address>                 pair (numeric comparison is confirmed, the code is printed)
//   bridge <address> <port>        open RFCOMM to the watch's Wear OS service and relay it
//                                  to one TCP client on 127.0.0.1:<port>
//
// Built as an app bundle (see build.sh) so macOS asks for Bluetooth permission
// for this tool only.

import CoreBluetooth
import Foundation
import IOBluetooth
import Network

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

// MARK: - BLE scan

final class LEScanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var seen = Set<UUID>()
    private let onlyGoogle: Bool

    init(onlyGoogle: Bool) {
        self.onlyGoogle = onlyGoogle
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("le: state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
            log("le: scanning")
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard !seen.contains(peripheral.identifier) else { return }
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var company = -1
        if let data = manufacturer, data.count >= 2 { company = Int(data[0]) | Int(data[1]) << 8 }
        if onlyGoogle && company != 0x00E0 { return }
        seen.insert(peripheral.identifier)
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-"
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        var line = "le: \(peripheral.identifier) rssi=\(RSSI) name=\(name) connectable=\(connectable)"
        if let data = manufacturer {
            line += String(format: " company=0x%04x", company) + " data=\(hex(data))"
        }
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            line += " services=\(services.map(\.uuidString))"
        }
        log(line)
    }
}

// MARK: - Classic inquiry

final class ClassicInquiry: NSObject, IOBluetoothDeviceInquiryDelegate {
    private var inquiry: IOBluetoothDeviceInquiry!
    var done = false

    func start(seconds: Int) {
        inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry.inquiryLength = UInt8(min(max(seconds, 1), 60))
        inquiry.updateNewDeviceNames = true
        log("classic: inquiry start result=\(inquiry.start())")
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        log(
            "classic: found \(device.addressString ?? "?") name=\(device.name ?? "-") "
                + String(format: "class=0x%06x", device.classOfDevice)
        )
    }

    func deviceInquiryDeviceNameUpdated(
        _ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32
    ) {
        log("classic: name \(device.addressString ?? "?") = \(device.name ?? "-")")
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        log("classic: inquiry complete error=\(error) aborted=\(aborted)")
        done = true
    }
}

// MARK: - SDP

final class SDPQuery: NSObject {
    private let device: IOBluetoothDevice
    var done = false

    init(device: IOBluetoothDevice) { self.device = device }

    func start() {
        log("sdp: query \(device.addressString ?? "?") result=\(device.performSDPQuery(self))")
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        log("sdp: complete status=\(status)")
        for record in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            log("sdp: service \(describe(record))")
        }
        done = true
    }
}

// MARK: - Pairing

final class Pairing: NSObject, IOBluetoothDevicePairDelegate {
    private var pair: IOBluetoothDevicePair!
    var done = false
    var succeeded = false

    func start(device: IOBluetoothDevice) {
        pair = IOBluetoothDevicePair(device: device)
        pair.delegate = self
        log("pair: start \(device.addressString ?? "?") result=\(pair.start())")
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
        succeeded = error == kIOReturnSuccess
        done = true
    }
}

// MARK: - Bridge

final class Bridge: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let device: IOBluetoothDevice
    private let port: UInt16
    private var channel: IOBluetoothRFCOMMChannel?
    private var listener: NWListener?
    private var client: NWConnection?
    private var toClient = Data()
    var finished = false

    init(device: IOBluetoothDevice, port: UInt16) {
        self.device = device
        self.port = port
    }

    func start() {
        log("bridge: SDP query result=\(device.performSDPQuery(self))")
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        guard let record = records.first(where: { $0.matchesUUIDArray([wearServiceUUID()]) }) else {
            log("bridge: Wear OS service not found (status=\(status), \(records.count) services)")
            records.forEach { log("bridge: service \(describe($0))") }
            finished = true
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            log("bridge: Wear OS service has no RFCOMM channel")
            finished = true
            return
        }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        log("bridge: opening RFCOMM channel \(channelID) result=\(result)")
        channel = opened
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        log("bridge: RFCOMM open status=\(error) mtu=\(rfcommChannel.getMTU())")
        guard error == kIOReturnSuccess else {
            finished = true
            return
        }
        startListener()
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        let data = Data(bytes: dataPointer, count: dataLength)
        log("bridge: watch -> phone \(data.count) bytes \(hex(data, limit: 24))")
        if let client {
            client.send(content: data, completion: .contentProcessed { _ in })
        } else {
            toClient.append(data)
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log("bridge: RFCOMM closed")
        client?.cancel()
        finished = true
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port),
            let listener = try? NWListener(using: parameters, on: nwPort)
        else {
            log("bridge: cannot listen on port \(port)")
            finished = true
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { state in log("bridge: listener \(state)") }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        guard client == nil else {
            log("bridge: second client refused")
            connection.cancel()
            return
        }
        log("bridge: relay connected")
        client = connection
        connection.start(queue: .main)
        if !toClient.isEmpty {
            connection.send(content: toClient, completion: .contentProcessed { _ in })
            toClient.removeAll()
        }
        receive(from: connection)
    }

    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.writeToWatch(data) }
            if isComplete || error != nil {
                log("bridge: relay closed \(String(describing: error))")
                self.client = nil
                return
            }
            self.receive(from: connection)
        }
    }

    private func writeToWatch(_ data: Data) {
        guard let channel else { return }
        log("bridge: phone -> watch \(data.count) bytes \(hex(data, limit: 24))")
        let mtu = max(Int(channel.getMTU()), 1)
        var offset = 0
        while offset < data.count {
            var chunk = data.subdata(in: offset..<min(offset + mtu, data.count))
            let result = chunk.withUnsafeMutableBytes { buffer in
                channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
            }
            if result != kIOReturnSuccess { log("bridge: write failed \(result)") }
            offset += mtu
        }
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
    let scanner = LEScanner(onlyGoogle: arguments.contains("--google"))
    runLoop(timeout: seconds)
    withExtendedLifetime(scanner) { log("le: done") }

case "inquiry":
    let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 15
    let inquiry = ClassicInquiry()
    inquiry.start(seconds: seconds)
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
    let query = SDPQuery(device: target)
    query.start()
    runLoop(timeout: 30) { query.done }

case "pair":
    guard arguments.count >= 2, let target = device(for: arguments[1]) else {
        log("usage: pair <address>")
        exit(2)
    }
    let pairing = Pairing()
    pairing.start(device: target)
    runLoop(timeout: 90) { pairing.done }
    exit(pairing.succeeded ? 0 : 1)

case "bridge":
    guard arguments.count >= 3, let target = device(for: arguments[1]),
        let port = UInt16(arguments[2])
    else {
        log("usage: bridge <address> <port>")
        exit(2)
    }
    let bridge = Bridge(device: target, port: port)
    bridge.start()
    runLoop(timeout: .infinity) { bridge.finished }

default:
    print(
        """
        usage: PixelWatchBridge le-scan [seconds] [--google] | inquiry [seconds] | paired
               | sdp <address> | pair <address> | bridge <address> <port>
        """)
}
