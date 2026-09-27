import XCTest
import CoreAudio
import CoreMedia
@testable import DoublEnder

final class AppStateTests: XCTestCase {

    func testOutputFormatExtensions() {
        XCTAssertEqual(OutputFormat.aac.fileExtension, "m4a")
        XCTAssertEqual(OutputFormat.wav.fileExtension, "wav")
    }

    func testMinimumFreeBytesScalesWithFormat() {
        XCTAssertLessThan(
            DiskSpaceChecker.minimumFreeBytes(for: .aac),
            DiskSpaceChecker.minimumFreeBytes(for: .wav)
        )
    }

    func testRecordingBlockedWhenSpaceCannotBeQueried() {
        // Fail-closed contract: if the volume's free-space API returns nil
        // (e.g., the directory doesn't exist), recording is blocked rather
        // than silently allowed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        let reason = DiskSpaceChecker.recordingBlockedReason(for: dir, format: .aac)
        XCTAssertNotNil(reason)
    }
}

/// What the Cloud heartbeat reports, held to its privacy rules. The rules
/// live in shared code so that these run in the Local build too.
final class SessionDiagnosticsTests: XCTestCase {

    func testSystemInfoDescribesThisMac() {
        let system = SessionDiagnostics.SystemInfo.current
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertTrue(system.os.hasPrefix("\(version.majorVersion).\(version.minorVersion)"), system.os)
        #if arch(arm64)
        XCTAssertEqual(system.arch, "arm64")
        #else
        XCTAssertEqual(system.arch, "x86_64")
        #endif
        XCTAssertNotNil(system.model)
        XCTAssertGreaterThan(system.memoryGB, 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(system.json))
    }

    /// Nothing about the Mac names its owner.
    func testSystemInfoCarriesNoAccountName() {
        let values = SessionDiagnostics.SystemInfo.current.json.values.compactMap { $0 as? String }
        for name in [NSUserName(), NSFullUserName()] where name.count >= 4 {
            XCTAssertFalse(values.contains { $0.contains(name) }, "\(values) contains \(name)")
        }
    }

    func testInputNameOnlyWhereTheHardwareSuppliesIt() {
        let hardwareNamed = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
        ]
        for transport in hardwareNamed {
            XCTAssertEqual(
                SessionDiagnostics.reportableName("Scarlett 2i2 USB", transport: transport),
                "Scarlett 2i2 USB"
            )
        }
        let ownerNamed = [
            kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeAVB,
            kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeUnknown, fourCC("ccap"),
        ]
        for transport in ownerNamed {
            XCTAssertNil(SessionDiagnostics.reportableName("Jane's AirPods Pro", transport: transport))
        }
        XCTAssertNil(SessionDiagnostics.reportableName("Jane's AirPods Pro", transport: nil))
    }

    func testBluetoothHeadsetIsReportedWithoutItsName() {
        let info = SessionDiagnostics.InputInfo(
            transport: kAudioDeviceTransportTypeBluetooth, manufacturer: "Apple Inc.",
            name: "Jane's AirPods Pro", format: nil
        )
        XCTAssertNil(info.name)
        XCTAssertEqual(info.transport, "bluetooth")
        XCTAssertEqual(info.manufacturer, "Apple Inc.")
        XCTAssertFalse("\(info.json)".contains("Jane"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(info.json))
    }

    func testInputInfoDescribesTheFormat() throws {
        let format = try makeFormat(channels: 2, bits: 24, layout: channelLayout(
            tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        ))
        let info = SessionDiagnostics.InputInfo(
            transport: kAudioDeviceTransportTypeUSB, manufacturer: "Focusrite",
            name: "Scarlett 2i2 USB", format: format
        )
        XCTAssertEqual(info.transport, "usb")
        XCTAssertEqual(info.name, "Scarlett 2i2 USB")
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sampleFormat, "int24")
        XCTAssertEqual(info.layout, "L R")
        XCTAssertEqual(info.meterMatchesFile, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(info.json))
    }

    func testLayoutDescriptions() throws {
        func describe(_ channels: UInt32, _ layout: Data?) throws -> String {
            SessionDiagnostics.layoutDescription(try makeFormat(channels: channels, bits: 24, layout: layout))
        }
        XCTAssertEqual(try describe(2, nil), "none")
        XCTAssertEqual(try describe(2, channelLayout(tag: kAudioChannelLayoutTag_Stereo)), "Stereo")
        XCTAssertEqual(
            try describe(2, channelLayout(tag: kAudioChannelLayoutTag_DiscreteInOrder | 2)),
            "DiscreteInOrder 2"
        )
        XCTAssertEqual(
            try describe(2, channelLayout(
                tag: kAudioChannelLayoutTag_UseChannelDescriptions,
                labels: [kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Discrete_1]
            )),
            "D0 D1"
        )
        // AudioUnit_5_0: layout 153, five channels, not a named tag here.
        XCTAssertEqual(try describe(5, channelLayout(tag: (153 << 16) | 5)), "tag 153/5")
    }

    /// The flag the dashboard uses to trust the meter: false where the mixer
    /// falls back because the writer's mix of that layout wasn't measured.
    func testMeterMatchesFileOnlyForMeasuredLayouts() throws {
        let unmeasured = SessionDiagnostics.InputInfo(
            transport: kAudioDeviceTransportTypeUSB, manufacturer: nil, name: nil,
            format: try makeFormat(channels: 4, bits: 24, layout: nil)
        )
        XCTAssertEqual(unmeasured.meterMatchesFile, false)
        let discrete = SessionDiagnostics.InputInfo(
            transport: kAudioDeviceTransportTypeUSB, manufacturer: nil, name: nil,
            format: try makeFormat(
                channels: 2, bits: 24,
                layout: channelLayout(tag: kAudioChannelLayoutTag_DiscreteInOrder | 2)
            )
        )
        XCTAssertEqual(discrete.meterMatchesFile, true)
    }

    func testSampleFormatNames() throws {
        XCTAssertEqual(
            SessionDiagnostics.sampleFormat(try streamDescription(
                makeFormat(channels: 2, bits: 32, float: true, planar: true, layout: nil)
            )),
            "float32 planar"
        )
        XCTAssertEqual(
            SessionDiagnostics.sampleFormat(try streamDescription(makeFormat(channels: 1, bits: 16, layout: nil))),
            "int16"
        )
        var aac = AudioStreamBasicDescription()
        aac.mFormatID = kAudioFormatMPEG4AAC
        XCTAssertEqual(SessionDiagnostics.sampleFormat(aac), "aac ")
    }

    func testTransportNames() {
        XCTAssertEqual(SessionDiagnostics.transportName(kAudioDeviceTransportTypeBuiltIn), "builtIn")
        XCTAssertEqual(SessionDiagnostics.transportName(kAudioDeviceTransportTypeUSB), "usb")
        XCTAssertEqual(SessionDiagnostics.transportName(fourCC("ccwl")), "continuity")
        XCTAssertEqual(SessionDiagnostics.transportName(fourCC("zzzz")), "other:zzzz")
        XCTAssertEqual(SessionDiagnostics.transportName(nil), "unknown")
    }

    func testTakeEnd() {
        let url = URL(fileURLWithPath: "/tmp/take.m4a")
        let noActive = RecordingError.noActiveRecording
        let notFinalized = RecordingError.writerFinishedWithError("disk full")
        XCTAssertEqual(SessionDiagnostics.takeEnd(result: .success(url), sidecarHasAudio: false), .saved)
        XCTAssertEqual(SessionDiagnostics.takeEnd(result: .success(nil), sidecarHasAudio: false), .noAudio)
        XCTAssertEqual(SessionDiagnostics.takeEnd(result: .failure(noActive), sidecarHasAudio: false), .noAudio)
        XCTAssertEqual(SessionDiagnostics.takeEnd(result: .failure(notFinalized), sidecarHasAudio: true), .recovered)
        XCTAssertEqual(SessionDiagnostics.takeEnd(result: .failure(notFinalized), sidecarHasAudio: false), .failed)
    }

    func testTakeCause() {
        XCTAssertEqual(SessionDiagnostics.takeCause(diskStop: true, engineStop: true, failure: .dataStalled), "diskSpace")
        XCTAssertEqual(SessionDiagnostics.takeCause(diskStop: false, engineStop: true, failure: .dataStalled), "dataStalled")
        XCTAssertEqual(SessionDiagnostics.takeCause(diskStop: false, engineStop: false, failure: nil), "user")
    }

    func testCrashBackupState() {
        XCTAssertEqual(SessionDiagnostics.crashBackupState(unavailable: false, failed: false), "ok")
        XCTAssertEqual(SessionDiagnostics.crashBackupState(unavailable: true, failed: false), "unavailable")
        XCTAssertEqual(SessionDiagnostics.crashBackupState(unavailable: false, failed: true), "failed")
    }

    func testTakeInfoIsValidJSON() {
        let take = SessionDiagnostics.TakeInfo(
            end: .saved, cause: "user", seconds: 42, droppedFrames: false,
            interruptions: 1, crashBackup: "ok"
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(take.json))
        XCTAssertEqual(take.json["end"] as? String, "saved")
    }

    /// An error's message can name a device; only the state's name is sent.
    func testAppStateNameDropsItsPayload() {
        XCTAssertEqual(AppState.error("Jane's AirPods Pro was disconnected").diagnosticName, "error")
        XCTAssertEqual(AppState.ready.diagnosticName, "ready")
    }

    // MARK: - Helpers

    private func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A 48 kHz linear PCM format description, labelled by `layout` if given.
    /// The format's stream description, copied out while the format is still
    /// alive: the pointer CoreMedia returns points into the format itself.
    private func streamDescription(_ format: CMAudioFormatDescription) throws -> AudioStreamBasicDescription {
        try withExtendedLifetime(format) {
            try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        }
    }

    private func makeFormat(
        channels: UInt32, bits: UInt32, float: Bool = false, planar: Bool = false, layout: Data?
    ) throws -> CMAudioFormatDescription {
        let bytesPerSample = bits / 8
        var flags = float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        flags |= kAudioFormatFlagIsPacked
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = planar ? bytesPerSample : bytesPerSample * channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let layoutBytes = layout ?? Data()
        let status = layoutBytes.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: raw.count,
                layout: raw.isEmpty ? nil : raw.baseAddress?.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else {
            throw NSError(domain: "SessionDiagnosticsTests", code: Int(status))
        }
        return format
    }

    /// An AudioChannelLayout's bytes: `tag`, and a description per label.
    private func channelLayout(tag: AudioChannelLayoutTag, labels: [AudioChannelLabel] = []) -> Data {
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
        let stride = MemoryLayout<AudioChannelDescription>.stride
        var data = Data(count: max(MemoryLayout<AudioChannelLayout>.size, offset + labels.count * stride))
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = tag
            layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
            for (index, label) in labels.enumerated() {
                (base + offset + index * stride).storeBytes(
                    of: AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0)),
                    as: AudioChannelDescription.self
                )
            }
        }
        return data
    }
}
