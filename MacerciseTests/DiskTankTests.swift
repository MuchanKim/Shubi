import Foundation
import Testing
@testable import Macercise

struct DiskTankTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func moveEasesFromItsStartToItsTarget() {
        let move = TankMotion.Move(from: 0.2, to: 0.8, start: start, duration: 2)
        #expect(move.level(at: start) == 0.2)
        #expect(abs(move.level(at: start + 1) - 0.5) < 1e-9)
        #expect(move.level(at: start + 2) == 0.8)
        #expect(move.level(at: start + 10) == 0.8)
        // Eased: it starts slower than a linear move would.
        #expect(move.level(at: start + 0.2) - 0.2 < 0.6 * 0.1)
    }

    @Test(arguments: [(0.5, 0.51, 1.0), (0.5, 0.49, 1.0), (0.1, 0.5, 1.0), (0.1, 0.9, 1.6), (0, 1, 2.0), (1, 0, 2.0)])
    func durationIsProportionalWithAOneSecondFloor(from: Double, to: Double, seconds: Double) {
        let still = TankMotion.Move(from: from, to: from, start: start, duration: 0)
        #expect(abs(still.retargeted(to: to, at: start).duration - seconds) < 1e-9)
    }

    @Test func retargetingMidMoveNeitherJumpsNorStops() {
        let rising = TankMotion.Move(from: 0, to: 0, start: start, duration: 0).retargeted(to: 0.5, at: start)
        let now = start + 0.5
        let farther = rising.retargeted(to: 0.9, at: now)
        #expect(abs(farther.level(at: now) - rising.level(at: now)) < 1e-9)
        #expect(abs(farther.velocity(at: now) - rising.velocity(at: now)) < 1e-9)
        #expect(farther.velocity(at: now) > 0)
    }

    @Test func aNewTargetBehindTheWaterStartsFromRest() {
        let rising = TankMotion.Move(from: 0.2, to: 0.8, start: start, duration: 1.2)
        let now = start + 0.6
        let back = rising.retargeted(to: 0.3, at: now)
        #expect(abs(back.level(at: now) - rising.level(at: now)) < 1e-9)
        #expect(back.velocity(at: now) == 0)
    }

    @Test(arguments: [0.51, 0.55, 0.7, 0.9])
    func carriedSpeedNeverOvershootsTheTarget(target: Double) {
        // Rising fast through 0.5, then told to stop just above it.
        let fast = TankMotion.Move(from: 0, to: 1, start: start, duration: 2)
        let now = start + 1
        let move = fast.retargeted(to: target, at: now)
        let here = move.level(at: now)
        for step in 0...100 {
            let level = move.level(at: now + move.duration * Double(step) / 100)
            #expect(level >= here - 1e-9 && level <= target + 1e-9)
        }
    }

    @Test func scansLandingQuicklyKeepTheWaterMoving() {
        // Eleven scans finishing 0.1 s apart, each raising the level a step toward 0.88.
        var move = TankMotion.Move(from: 0, to: 0, start: start, duration: 0)
        for step in 1...11 {
            move = move.retargeted(to: Double(step) * 0.08, at: start + Double(step) * 0.1)
        }
        let last = start + 1.1
        // Restarting from rest at every scan would leave it under a tenth of the way after 1.1 s.
        #expect(move.level(at: last) > 0.25)
        #expect(move.level(at: last + 2) == 0.88)
    }

    @Test func higherLevelsRaiseBothWavesTogether() {
        let levels = stride(from: 0.0, through: 1, by: 0.05)
        let front = levels.map { TankMotion.frontWave.position(forLevel: $0).y }
        let back = levels.map { TankMotion.backWave.position(forLevel: $0).y }
        // y grows downward: a higher level is a smaller y.
        #expect(front == front.sorted(by: >))
        #expect(front == back)
    }

    @Test(arguments: [-0.5, 0, 0.5, 1, 1.5])
    func everyLevelStaysOnTheDesignedPath(level: Double) {
        let fraction = TankMotion.pathFraction(forLevel: level)
        #expect((0...1).contains(fraction))
        #expect(fraction == TankMotion.pathFraction(forLevel: min(max(level, 0), 1)))
    }
}

@MainActor
struct DiskBreakdownTests {
    static let gb: Int64 = 1_000_000_000

    @Test func barShowsReclaimableThenOtherUsedThenFree() {
        let split = DiskBreakdown(sections: [(.developer, 100 * Self.gb), (.logs, 20 * Self.gb)], disk: (500 * Self.gb, 50 * Self.gb))
        #expect(split.reclaimable == 120 * Self.gb)
        #expect(split.otherUsed == 330 * Self.gb)
        #expect(abs(split.fractionOfBar(split.reclaimable) - 0.24) < 1e-9)
        let whole = split.fractionOfBar(split.reclaimable) + split.fractionOfBar(split.otherUsed) + split.fractionOfBar(50 * Self.gb)
        #expect(abs(whole - 1) < 1e-9)
    }

    @Test func scansLargerThanTheUsedSpaceNeverOverflowTheBar() {
        // Clones and purgeable space: the scans count 480 GB on a disk that reports 450 GB used.
        let split = DiskBreakdown(sections: [(.developer, 480 * Self.gb)], disk: (500 * Self.gb, 50 * Self.gb))
        #expect(split.otherUsed == 0)
        let whole = split.fractionOfBar(split.reclaimable) + split.fractionOfBar(split.otherUsed) + split.fractionOfBar(50 * Self.gb)
        #expect(abs(whole - 1) < 1e-9)
        #expect(split.fractionOfBar(split.reclaimable) < 1)
    }

    @Test func sharesSplitTheReclaimableTotal() {
        let split = DiskBreakdown(sections: [(.developer, 90 * Self.gb), (.browser, 9 * Self.gb), (.logs, 1 * Self.gb)], disk: nil)
        #expect(abs(split.sections.map { split.share($0.size) }.reduce(0, +) - 1) < 1e-9)
        #expect(abs(split.share(9 * Self.gb) - 0.09) < 1e-9)
    }

    @Test func beforeAnySectionFinishesEverythingUsedIsOther() {
        let split = DiskBreakdown(sections: [], disk: (500 * Self.gb, 50 * Self.gb))
        #expect(split.reclaimable == 0)
        #expect(split.otherUsed == 450 * Self.gb)
        #expect(split.share(0) == 0)
    }

    @Test func withoutTheDiskSizeThereIsNoBarButSharesStillAddUp() {
        let split = DiskBreakdown(sections: [(.developer, 3 * Self.gb), (.logs, 1 * Self.gb)], disk: nil)
        #expect(split.fractionOfBar(split.reclaimable) == 0)
        #expect(split.otherUsed == 0)
        #expect(split.share(1 * Self.gb) == 0.25)
    }

    @Test func wordsUseTheRealDiskAndTheEstimateIsWhatStaysUsed() throws {
        let split = DiskBreakdown(sections: [(.developer, 100 * Self.gb)], disk: (500 * Self.gb, 100 * Self.gb))
        #expect(split.fractionOfDisk(split.reclaimable) == 0.2)
        #expect(try #require(split.cleanedLevel) == 0.6)
    }

    @Test func scansLargerThanTheUsedSpaceGiveNoEstimateAndTheRealRatio() throws {
        let split = DiskBreakdown(sections: [(.developer, 480 * Self.gb)], disk: (500 * Self.gb, 50 * Self.gb))
        #expect(split.cleanedLevel == nil)
        #expect(abs(try #require(split.fractionOfDisk(split.reclaimable)) - 0.96) < 1e-9)
    }

    @Test func nothingToCleanOrNoDiskSizeGivesNoEstimate() {
        #expect(DiskBreakdown(sections: [], disk: (500 * Self.gb, 50 * Self.gb)).cleanedLevel == nil)
        #expect(DiskBreakdown(sections: [(.logs, 1 * Self.gb)], disk: nil).cleanedLevel == nil)
    }

    @Test func aDiskReportingNoCapacityGivesNoRatio() {
        let split = DiskBreakdown(sections: [(.logs, 1 * Self.gb)], disk: (0, 0))
        #expect(split.fractionOfDisk(split.reclaimable) == nil)
        #expect(split.cleanedLevel == nil)
    }
}
