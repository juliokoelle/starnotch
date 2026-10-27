import Testing
import TestSupport
@testable import NotchCore

@Suite struct SystemStatsTests {
    @Test func cpuFromTicks() {
        let before = [CoreTicks(user: 100, system: 50, idle: 850, nice: 0), CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let after = [CoreTicks(user: 160, system: 70, idle: 870, nice: 0), CoreTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let load = CPULoad.usage(previous: before, current: after)
        #expect(abs(load.cores[0] - 0.8) < 0.0001)       // 80 busy of 100
        #expect(load.cores[1] == 0)
        #expect(abs(load.total - 0.4) < 0.0001)          // 80 of 200
        // A wrapped counter counts as idle, never negative.
        let wrapped = CPULoad.usage(previous: after, current: before)
        #expect(wrapped.total == 0 && wrapped.cores == [0, 0])
    }

    @Test func memoryLikeActivityMonitor() {
        let gb: UInt64 = 1_073_741_824, page: UInt64 = 16_384
        let stats = MemoryStats.from(pageSize: page, internalPages: 6 * gb / page, purgeablePages: 1 * gb / page,
                                     wiredPages: 2 * gb / page, compressorPages: 1 * gb / page,
                                     total: 24 * gb, swapUsed: 3 * gb, pressureLevel: 2)
        #expect(stats.app == 5 * gb)
        #expect(stats.used == 8 * gb)
        #expect(stats.pressure == .warn)
        #expect(abs(stats.fraction - 1.0 / 3) < 0.0001)
        #expect(MemoryStats.from(pageSize: page, internalPages: 0, purgeablePages: 5, wiredPages: 0, compressorPages: 0,
                                 total: gb, swapUsed: 0, pressureLevel: 4).pressure == .critical)
    }

    @Test func gpuUtilization() {
        #expect(GPUStats.utilization(["Device Utilization %": 47, "Renderer Utilization %": 40]) == 0.47)
        #expect(GPUStats.utilization(["Renderer Utilization %": 12]) == 0.12)
        #expect(GPUStats.utilization([:]) == nil)
    }

    @Test func helpersGroupUnderTheirApp() {
        let mb: UInt64 = 1_048_576
        let processes = [
            ProcessSample(pid: 1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", name: "Google Chrome", cpu: 0.10, memory: 500 * mb),
            ProcessSample(pid: 2, path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", name: "Google Chrome Helper (Renderer)", cpu: 0.30, memory: 900 * mb),
            ProcessSample(pid: 3, path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", name: "Claude Helper", cpu: 0.05, memory: 300 * mb),
            ProcessSample(pid: 4, path: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude", cpu: 0.01, memory: 200 * mb),
            ProcessSample(pid: 5, path: "/Users/x/.local/share/claude/versions/2.1.306", name: "claude", cpu: 0.20, memory: 400 * mb),
            ProcessSample(pid: 6, path: "/Users/x/.local/share/claude/versions/2.1.306", name: "claude", cpu: 0.25, memory: 350 * mb),
            ProcessSample(pid: 7, path: "/usr/libexec/sharingd", name: "sharingd", cpu: 0.02, memory: 20 * mb),
        ]
        let byCPU = ProcessGrouping.group(processes, sort: .cpu)
        #expect(byCPU.map(\.name) == ["Claude Code", "Google Chrome", "Claude", "sharingd"])
        #expect(abs(byCPU[0].cpu - 0.45) < 0.0001 && byCPU[0].processes == 2)
        #expect(byCPU[1].memory == 1400 * mb && byCPU[1].bundlePath == "/Applications/Google Chrome.app")
        #expect(byCPU[2].memory == 500 * mb)
        let byMemory = ProcessGrouping.group(processes, sort: .memory, limit: 2)
        #expect(byMemory.map(\.name) == ["Google Chrome", "Claude Code"])
        #expect(ProcessGrouping.bundle(of: "/Applications/Foo.app") == "/Applications/Foo.app")
        #expect(ProcessGrouping.bundle(of: "/bin/zsh") == nil)
    }

    @Test func alertOncePerEpisode() {
        var alert = SystemAlert()
        #expect(!feed(&alert, 0.9, .normal, "10:00"))       // hot, not for 30 s yet
        #expect(feed(&alert, 0.95, .normal, "10:01"))       // hot for a minute: once
        #expect(alert.level == .warn)
        #expect(!feed(&alert, 0.95, .normal, "10:02"))
        #expect(!feed(&alert, 0.2, .normal, "10:03"))       // calm again
        #expect(alert.level == .none)
        #expect(feed(&alert, 0.2, .critical, "10:04"))      // a new episode
        #expect(alert.level == .critical)
    }

    private func feed(_ alert: inout SystemAlert, _ cpu: Double, _ pressure: MemoryStats.Pressure, _ time: String) -> Bool {
        alert.update(cpu: cpu, pressure: pressure, now: UTC.date("2026-10-22 \(time)"))
    }

    @Test func bytes() {
        #expect(ByteText.short(3_328_599_654) == "3.1 GB")
        #expect(ByteText.short(640 * 1_048_576) == "640 MB")
        #expect(ByteText.short(12 * 1_073_741_824) == "12 GB")
    }

    @Test func networkRate() {
        let before = NetworkTotals(received: 1_000_000, sent: 200_000)
        let after = NetworkTotals(received: 5_194_304, sent: 210_240)
        let rate = NetworkRate.rate(previous: before, current: after, seconds: 2)
        #expect(rate.down == 2_097_152)
        #expect(rate.up == 5_120)
        // An interface that went away lowers the totals: 0, never negative; no time, no rate.
        let back = NetworkRate.rate(previous: after, current: before, seconds: 2)
        #expect(back.down == 0 && back.up == 0)
        let instant = NetworkRate.rate(previous: before, current: after, seconds: 0)
        #expect(instant.down == 0 && instant.up == 0)
    }

    @Test func rateText() {
        #expect(ByteText.rate(2_097_152) == "2.0 MB/s")
        #expect(ByteText.rate(18 * 1_048_576) == "18 MB/s")
        #expect(ByteText.rate(5_120) == "5 KB/s")
        #expect(ByteText.rate(0) == "0 KB/s")
    }
}
