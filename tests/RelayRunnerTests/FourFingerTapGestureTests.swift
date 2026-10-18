import XCTest
@testable import relay_runner

final class FourFingerTapGestureTests: XCTestCase {
    private func contacts(_ count: Int = 4, dx: CGFloat = 0) -> [FourFingerTapGesture.Contact] {
        (0..<count).map { .init(id: Int32($0), position: CGPoint(x: 0.25 + CGFloat($0) * 0.1 + dx, y: 0.5)) }
    }

    func testFourFingersCanLandAndLiftSeparatelyAndFireOnlyOnce() {
        var gesture = FourFingerTapGesture()
        for (count, time) in [(1, 0.0), (3, 0.02), (4, 0.04), (4, 0.1), (2, 0.15), (1, 0.18)] {
            XCTAssertFalse(gesture.update(contacts: contacts(count), at: time))
        }
        XCTAssertTrue(gesture.update(contacts: [], at: 0.2))
        XCTAssertFalse(gesture.update(contacts: [], at: 0.21))
        XCTAssertFalse(gesture.update(contacts: contacts(), at: 0.4))
        XCTAssertTrue(gesture.update(contacts: [], at: 0.55))
    }

    func testFiveFingersNeverFireEvenWhenOneLiftsFirst() {
        var gesture = FourFingerTapGesture()
        XCTAssertFalse(gesture.update(contacts: contacts(5), at: 0))
        XCTAssertFalse(gesture.update(contacts: contacts(), at: 0.1))
        XCTAssertFalse(gesture.update(contacts: [], at: 0.2))
    }

    func testStationaryThreeFingersNeverFire() {
        var gesture = FourFingerTapGesture()
        _ = gesture.update(contacts: contacts(3), at: 0)
        XCTAssertFalse(gesture.update(contacts: [], at: 0.2))
    }

    func testSwipeRemainsRejectedAfterReturningToItsOrigin() {
        var gesture = FourFingerTapGesture()
        _ = gesture.update(contacts: contacts(), at: 0)
        _ = gesture.update(contacts: contacts(dx: 0.08), at: 0.1)
        _ = gesture.update(contacts: contacts(), at: 0.15)
        XCTAssertFalse(gesture.update(contacts: [], at: 0.2))
    }

    func testPinchWithUnchangedCentroidIsRejected() {
        var gesture = FourFingerTapGesture()
        _ = gesture.update(contacts: contacts(), at: 0)
        let pinch = contacts().enumerated().map { index, contact in
            FourFingerTapGesture.Contact(id: contact.id,
                position: CGPoint(x: contact.position.x + (index < 2 ? -0.08 : 0.08), y: contact.position.y))
        }
        _ = gesture.update(contacts: pinch, at: 0.1)
        XCTAssertFalse(gesture.update(contacts: [], at: 0.2))
    }

    func testSmallJitterStillCountsAsATap() {
        var gesture = FourFingerTapGesture()
        _ = gesture.update(contacts: contacts(), at: 0)
        _ = gesture.update(contacts: contacts(dx: 0.01), at: 0.1)
        XCTAssertTrue(gesture.update(contacts: [], at: 0.2))
    }

    func testHoldAndNoiseAreRejected() {
        for end in [0.01, 0.36, 1.0] {
            var gesture = FourFingerTapGesture()
            _ = gesture.update(contacts: contacts(), at: 0)
            XCTAssertFalse(gesture.update(contacts: [], at: end))
        }
    }

    func testClickDuringContactOrOnReleaseIsRejected() {
        for clickOnRelease in [false, true] {
            var gesture = FourFingerTapGesture()
            _ = gesture.update(contacts: contacts(), at: 0, buttonDown: !clickOnRelease)
            XCTAssertFalse(gesture.update(contacts: [], at: 0.2, buttonDown: clickOnRelease))
        }
    }

    func testRelandingAndReplacementFingersAreRejected() {
        var gesture = FourFingerTapGesture()
        _ = gesture.update(contacts: contacts(), at: 0)
        _ = gesture.update(contacts: contacts(3), at: 0.05)
        _ = gesture.update(contacts: contacts(), at: 0.1)
        XCTAssertFalse(gesture.update(contacts: [], at: 0.2))

        _ = gesture.update(contacts: contacts(), at: 1)
        let replaced = contacts().map { FourFingerTapGesture.Contact(id: $0.id + 4, position: $0.position) }
        _ = gesture.update(contacts: replaced, at: 1.1)
        XCTAssertFalse(gesture.update(contacts: [], at: 1.2))
    }

    func testCancellationDoesNotPoisonNextTap() {
        var gesture = FourFingerTapGesture()
        _ = gesture.update(contacts: contacts(), at: 0)
        gesture.cancel()
        XCTAssertFalse(gesture.update(contacts: [], at: 0.2))
        _ = gesture.update(contacts: contacts(), at: 1)
        XCTAssertTrue(gesture.update(contacts: [], at: 1.2))
    }

    func testContactDecoderIgnoresHoverAndReleasePhases() throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 96 * 8, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 96 * 8)
        for phase in 0..<8 {
            let record = buffer.advanced(by: phase * 96)
            record.storeBytes(of: Int32(phase), toByteOffset: 16, as: Int32.self)
            record.storeBytes(of: Int32(phase), toByteOffset: 20, as: Int32.self)
            record.storeBytes(of: Float(0.5), toByteOffset: 32, as: Float.self)
            record.storeBytes(of: Float(0.5), toByteOffset: 36, as: Float.self)
        }
        let decoded = try XCTUnwrap(FourFingerTapMonitor.decodeContacts(buffer, count: 8))
        XCTAssertEqual(decoded.map(\.id), [3, 4])
        XCTAssertEqual(decoded.map(\.position), [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)])
        buffer.storeBytes(of: Int32(99), toByteOffset: 20, as: Int32.self)
        XCTAssertNil(FourFingerTapMonitor.decodeContacts(buffer, count: 8))
    }

    func testContactDecoderRejectsInvalidOrDuplicateContacts() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 192, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 192)
        for offset in [0, 96] {
            buffer.storeBytes(of: Int32(3), toByteOffset: offset + 20, as: Int32.self)
            buffer.storeBytes(of: Float(0.5), toByteOffset: offset + 32, as: Float.self)
            buffer.storeBytes(of: Float(0.5), toByteOffset: offset + 36, as: Float.self)
        }
        XCTAssertNil(FourFingerTapMonitor.decodeContacts(buffer, count: 2))
        buffer.storeBytes(of: Float.nan, toByteOffset: 32, as: Float.self)
        XCTAssertNil(FourFingerTapMonitor.decodeContacts(buffer, count: 1))
        XCTAssertNil(FourFingerTapMonitor.decodeContacts(nil, count: 1))
        XCTAssertNil(FourFingerTapMonitor.decodeContacts(buffer, count: 17))
        XCTAssertNil(FourFingerTapMonitor.decodeContacts(buffer, count: -1))
        XCTAssertEqual(FourFingerTapMonitor.decodeContacts(nil, count: 0), [])
    }
}
