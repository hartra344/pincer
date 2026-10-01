import PincerKit

@MainActor
func runTranscriptPremeasureChecks() {
    let countLimit = TranscriptPremeasureBudget.rowLimit
    let byteLimit = TranscriptPremeasureBudget.sourceByteLimit
    var cache = BoundedLRUCache<Int, Int>(countLimit: countLimit, costLimit: byteLimit)

    for row in 0...countLimit {
        cache.insert(row, for: row, cost: 1)
    }
    check(cache.count <= countLimit, "transcript memo row count stays within its shared budget")

    cache.removeAll()
    let perRowCost = byteLimit / countLimit
    for row in 0..<countLimit {
        cache.insert(row, for: row, cost: perRowCost)
    }
    cache.insert(countLimit, for: countLimit, cost: perRowCost)
    check(cache.totalCost <= byteLimit, "transcript memo source retention stays within its shared byte budget")

    let retained = cache.count
    check(!cache.insert(-1, for: -1, cost: byteLimit + 1) && cache.count == retained,
          "a single oversized transcript body cannot displace bounded memo entries")
}
