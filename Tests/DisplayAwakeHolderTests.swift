import Foundation
import IOKit.pwr_mgt

@main enum DisplayAwakeHolderTests {
    static func main() {
        var acquired = 0, released: [IOPMAssertionID] = []
        var fail = true
        let holder = DisplayAwakeHolder(acquire: {
            acquired += 1
            return fail ? nil : 42
        }, release: { released.append($0) })
        holder.apply(keepAwake: false)
        assert(acquired == 0 && released.isEmpty)
        holder.apply(keepAwake: true)
        assert(!holder.isHolding)
        fail = false
        holder.apply(keepAwake: true)
        holder.apply(keepAwake: true)
        assert(acquired == 2 && holder.isHolding)
        holder.apply(keepAwake: false)
        holder.apply(keepAwake: false)
        assert(released == [42] && !holder.isHolding)
        print("PASS display opt-in: default off, failed acquisition retry, idempotent cleanup")
    }
}
