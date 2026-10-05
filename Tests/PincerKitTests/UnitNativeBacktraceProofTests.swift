#if DEBUG && os(macOS)
import Foundation
import Darwin
import MachO
import Testing
@testable import PincerKit

@inline(never) private func pincerOwnedSwiftCrashFrameForTesting() {
    UnsafeMutablePointer<UInt8>(bitPattern: 1)!.pointee = 0
    _exit(99)
}


private struct NativeLoadedImage: Codable {
    let basename: String
    let uuid: String
    let headerAddress: UInt64
}
private func loadedMappingImage(named names: Set<String>) throws -> NativeLoadedImage {
    let count = _dyld_image_count()
    try #require(count <= 2048)
    var matches: [NativeLoadedImage] = []
    for index in 0..<count {
        guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
        let basename = URL(fileURLWithPath: String(cString: name)).lastPathComponent
        guard names.contains(basename) else { continue }
        try #require(header.pointee.magic == MH_MAGIC_64)
        let raw = UnsafeRawPointer(header)
        let native = raw.load(as: mach_header_64.self)
        try #require(native.ncmds <= 4096 && native.sizeofcmds <= 1024 * 1024)
        var offset = 0, uuids: [String] = []
        let commands = raw.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<native.ncmds {
            try #require(offset <= Int(native.sizeofcmds) - MemoryLayout<load_command>.size)
            let command = commands.advanced(by: offset).load(as: load_command.self)
            try #require(command.cmdsize >= MemoryLayout<load_command>.size)
            let (end, overflow) = offset.addingReportingOverflow(Int(command.cmdsize))
            try #require(!overflow && end <= Int(native.sizeofcmds))
            if command.cmd == LC_UUID {
                try #require(command.cmdsize >= MemoryLayout<uuid_command>.size)
                let uuid = commands.advanced(by: offset).load(as: uuid_command.self).uuid
                uuids.append(withUnsafeBytes(of: uuid) { $0.map { String(format: "%02x", $0) }.joined() })
            }
            offset = end
        }
        try #require(uuids.count == 1)
        matches.append(NativeLoadedImage(basename: basename, uuid: uuids[0], headerAddress: UInt64(UInt(bitPattern: raw))))
    }
    try #require(matches.count == 1)
    return matches[0]
}
private func emitNativeImageMapping() throws {
    let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    try #require(handle != nil)
    // Retain the loaded framework through the real child fault/ordinary completion.
    let target = try loadedMappingImage(named: ["CoreGraphics"])
    let reference = try loadedMappingImage(named: ["PincerKitTests", "PincerPackageTests"])
    let data = try JSONEncoder().encode(["target": target, "reference": reference])
    print("PINCER_NATIVE_IMAGE_MAPPING=" + String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

@Suite(.timeLimit(.minutes(2)))
struct UnitNativeBacktraceProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_NATIVE_BACKTRACE_CHILD"] != nil))
    func actualOwnedSwiftCrashChild() throws {
        let mode = ProcessInfo.processInfo.environment["PINCER_NATIVE_BACKTRACE_CHILD"]
        try #require(mode == "ordinary" || mode == "crash")
        print("PINCER_NATIVE_BACKTRACE_CHILD_BEGIN")
        if ProcessInfo.processInfo.environment["PINCER_NATIVE_IMAGE_MAPPING_CONTROL"] == "1" {
            try emitNativeImageMapping()
        }
        if mode == "crash" {
            var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
            let coreDisabled = Darwin.setrlimit(RLIMIT_CORE, &coreLimit)
            try #require(coreDisabled == 0)
            print("PINCER_NATIVE_CRASH_PID=\(getpid())")
            fflush(stdout)
            pincerOwnedSwiftCrashFrameForTesting()
        }
        print("PINCER_NATIVE_BACKTRACE_CHILD_COMPLETE")
    }
    @Test func actualOwnedSwiftSignalRetainsNativeBacktrace() async throws {
        let evidence = try await unitNativeBacktraceProof()
        try #require(evidence.ordinaryPassed, "Actual one-child ordinary prerequisite: \(evidence.diagnostics)")
        try #require(evidence.crashOwnedStatus, "Actual SIGSEGV/PID metadata prerequisite: \(evidence.diagnostics)")
        #expect(evidence.crashBacktracePassed, "Actual owned Swift signal backtrace: \(evidence.diagnostics)")
        try #require(evidence.phases.count == 2)
        #expect(evidence.phases.map(\.mode) == ["ordinary", "crash"])
        #expect(evidence.phases.allSatisfy { $0.observationsFollowLaunch })
        #expect(evidence.phases.allSatisfy { $0.wrapperExitMilliseconds != nil })
    }
    @Test func actualLoadedImageMappingIsRetained() async throws {
        let override = ProcessInfo.processInfo.environment["PINCER_NATIVE_IMAGE_MAPPING_BACKTRACE_OVERRIDE"]
        let currentOptions = "enable=yes,interactive=no,color=no,timeout=0s,threads=crashed,registers=none,images=mentioned,limit=32,symbolicate=fast,sanitize=yes,output-to=stderr"
        if let override { try #require(override == currentOptions.replacingOccurrences(of: "images=mentioned", with: "images=all")) }
        let evidence = try await unitNativeBacktraceProof(backtraceOverrideForTesting: override, imageMappingControl: true)
        let diagnostics = await Task.detached(priority: .utility) {
            let mappings = String(decoding: (try? JSONEncoder().encode(evidence.imageMappings)) ?? Data(), as: UTF8.self)
            let phases = String(decoding: (try? JSONEncoder().encode(evidence.phases)) ?? Data(), as: UTF8.self)
            return "Native image scalar mappings: " + mappings + "\nNative image phases: " + phases
        }.value
        print(diagnostics)
        try #require(evidence.ordinaryPassed)
        try #require(evidence.crashOwnedStatus && evidence.crashBacktracePassed)
        let mappings = evidence.imageMappings
        try #require(mappings.count == 2)
        try #require(mappings.map(\.mode) == ["ordinary", "crash"])
        try #require(mappings.allSatisfy { $0.markerValid })
        try #require(mappings[0].targetBasename == mappings[1].targetBasename
                     && mappings[0].targetUUID == mappings[1].targetUUID)
        try #require(mappings[0].referenceBasename == mappings[1].referenceBasename
                     && mappings[0].referenceUUID == mappings[1].referenceUUID)
        try #require(mappings[1].imagesTablePresent && mappings[1].referenceMappingPresent)
        #expect(mappings[1].reportMappingPresent, "actual loaded CoreGraphics UUID and header address must be mapped")
    }
    @Test func actualFailedNativeControlRetainsBoundedOwnedArtifacts() async throws {
        let evidence = try await unitNativeRetentionProof()
        try #require(evidence.actualFailureQualified)
        #expect(evidence.retainedOwnedArtifacts && evidence.boundedManifest)
    }
}
#endif
