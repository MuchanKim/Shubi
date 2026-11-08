import Testing
@testable import Macercise

struct DiskTankTests {
    @Test func levelMapsToTheAssetsRiseFromEmptyToFull() {
        // Empty and full land where the bowl's bottom and top meet the water's mean surface (see `progress(forLevel:)`).
        #expect(abs(DiskTank.progress(forLevel: 0) - 0.0244) < 0.001)
        #expect(abs(DiskTank.progress(forLevel: 1) - 0.9102) < 0.001)
    }

    @Test func higherLevelMeansLaterProgress() {
        let progresses = stride(from: 0.0, through: 1, by: 0.05).map(DiskTank.progress(forLevel:))
        #expect(progresses == progresses.sorted())
    }

    @Test(arguments: [-0.5, 1.5])
    func outOfRangeLevelsAreClamped(level: Double) {
        #expect(DiskTank.progress(forLevel: level) == DiskTank.progress(forLevel: min(max(level, 0), 1)))
    }
}
