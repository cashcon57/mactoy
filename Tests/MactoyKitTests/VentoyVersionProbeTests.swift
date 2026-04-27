import Testing
import Foundation
@testable import MactoyKit

@Suite("VentoyVersionProbe.parseVentoyVersion")
struct VentoyVersionProbeParseTests {

    @Test("double-quoted version")
    func doubleQuoted() {
        let cfg = """
        set MENU_TIMEOUT=0
        set VENTOY_VERSION="1.1.05"
        set theme=$prefix/theme.cfg
        """
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "1.1.05")
    }

    @Test("single-quoted version")
    func singleQuoted() {
        let cfg = "set VENTOY_VERSION='1.0.99'"
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "1.0.99")
    }

    @Test("unquoted version (some Ventoy build configs)")
    func unquoted() {
        let cfg = "set VENTOY_VERSION=1.1.11"
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "1.1.11")
    }

    @Test("tolerant of whitespace around equals")
    func whitespace() {
        let cfg = "set  VENTOY_VERSION  =  \"1.0.50\""
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "1.0.50")
    }

    @Test("returns nil when no version line present")
    func missing() {
        let cfg = """
        # arbitrary grub.cfg without the version marker
        set timeout=10
        menuentry "Boot" { chainloader +1 }
        """
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == nil)
    }

    @Test("returns nil on empty input")
    func empty() {
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: "") == nil)
    }

    @Test("future-format-tolerant: 4-component version")
    func fourComponent() {
        // Hypothetical Ventoy 2.0.0.beta1 — parser should pass it
        // through without choking on extra dots.
        let cfg = "set VENTOY_VERSION=\"2.0.0.beta1\""
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "2.0.0.beta1")
    }

    @Test("future-format-tolerant: alphanumeric suffix")
    func alphanumericSuffix() {
        let cfg = "set VENTOY_VERSION=\"1.2.0-rc1\""
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "1.2.0-rc1")
    }

    @Test("first match wins when multiple lines (real grub.cfg has one)")
    func firstMatch() {
        let cfg = """
        set VENTOY_VERSION="1.1.05"
        # commented out: set VENTOY_VERSION="9.9.9"
        """
        #expect(VentoyVersionProbe.parseVentoyVersion(grubCfg: cfg) == "1.1.05")
    }
}

@Suite("VentoyProbeResult Codable round-trip")
struct VentoyProbeResultCodableTests {

    @Test("round-trip preserves all fields")
    func roundTrip() throws {
        let original = VentoyProbeResult(
            bsdName: "disk6",
            isVentoyDisk: true,
            detectedVersion: "1.1.05",
            secureBootEnabled: true,
            partitionStyle: .gpt,
            partition2StartSector: 244135936,
            layoutIssues: [],
            looksLikeBrokenVentoy: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VentoyProbeResult.self, from: data)
        #expect(decoded == original)
    }

    @Test("unknownDisk factory builds a clean not-Ventoy result")
    func unknownDiskFactory() {
        let r = VentoyProbeResult.unknownDisk(bsdName: "disk7", reason: "open failed: EPERM")
        #expect(r.bsdName == "disk7")
        #expect(r.isVentoyDisk == false)
        #expect(r.detectedVersion == nil)
        #expect(r.secureBootEnabled == false)
        #expect(r.partitionStyle == .unknown)
        #expect(r.partition2StartSector == 0)
        #expect(r.layoutIssues == ["open failed: EPERM"])
        #expect(r.looksLikeBrokenVentoy == false)
    }
}
