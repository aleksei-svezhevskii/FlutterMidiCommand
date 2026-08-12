import XCTest
import CoreMIDI
@testable import flutter_midi_command_darwin

/// Captures the per-packet data handed off by handlePacketList, bypassing the
/// byte parser and the main-queue stream handler dispatch.
private final class CapturingDevice: ConnectedVirtualOrNativeDevice {
    var received: [(data: Data, timestamp: UInt64)] = []

    override func parseData(data: Data, timestamp: UInt64) {
        received.append((data: data, timestamp: timestamp))
    }
}

final class PacketListHandlingTests: XCTestCase {

    private func makeDevice() -> CapturingDevice {
        return CapturingDevice(id: "test", type: "native", streamHandler: StreamHandler(), client: 0, ports: nil)
    }

    private func withPacketList(payloads: [[UInt8]], body: (UnsafePointer<MIDIPacketList>) -> Void) {
        let bufferSize = 4096
        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { rawBuffer.deallocate() }

        let packetList = rawBuffer.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(packetList)
        for (index, payload) in payloads.enumerated() {
            packet = MIDIPacketListAdd(packetList, bufferSize, packet, MIDITimeStamp(index + 1), payload.count, payload)
            XCTAssertNotNil(packet, "MIDIPacketListAdd overflowed the buffer")
        }
        XCTAssertEqual(Int(packetList.pointee.numPackets), payloads.count)

        body(UnsafePointer(packetList))
    }

    func testHandlesMultiPacketList() {
        // Three packets large enough that the second and third extend past the
        // 256 byte inline data window of a copied MIDIPacket struct, which is
        // where the old copy-based iteration returned garbage.
        func sysex(fill: UInt8, length: Int) -> [UInt8] {
            return [0xF0] + [UInt8](repeating: fill, count: length - 2) + [0xF7]
        }
        let payloads: [[UInt8]] = [
            sysex(fill: 0x11, length: 120),
            sysex(fill: 0x22, length: 120),
            sysex(fill: 0x33, length: 120),
        ]

        let device = makeDevice()
        withPacketList(payloads: payloads) { packetList in
            device.handlePacketList(packetList, srcConnRefCon: nil)
        }

        XCTAssertEqual(device.received.count, 3)
        for (index, payload) in payloads.enumerated() {
            XCTAssertEqual([UInt8](device.received[index].data), payload)
        }
    }

    func testHandlesPacketLargerThan256Bytes() {
        var sysex: [UInt8] = [0xF0]
        sysex.append(contentsOf: (0..<300).map { UInt8($0 % 0x80) })
        sysex.append(0xF7)

        let device = makeDevice()
        withPacketList(payloads: [sysex]) { packetList in
            device.handlePacketList(packetList, srcConnRefCon: nil)
        }

        XCTAssertEqual(device.received.count, 1)
        XCTAssertEqual(device.received[0].data.count, sysex.count)
        XCTAssertEqual([UInt8](device.received[0].data), sysex)
    }
}
