import Testing
@testable import CallSession

@Suite struct AsyncGateTests {

    private actor Recorder {
        private(set) var events: [Int] = []
        func add(_ value: Int) { events.append(value) }
    }

    @Test func criticalSectionsNeverInterleave() async {
        let gate = AsyncGate()
        let recorder = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    await gate.run {
                        await recorder.add(index * 2) // enter
                        try? await Task.sleep(for: .milliseconds(8))
                        await recorder.add(index * 2 + 1) // exit
                    }
                }
            }
        }
        let events = await recorder.events
        #expect(events.count == 8)
        // Every enter is immediately followed by its own exit: no
        // interleaving despite the suspension inside the section.
        for position in stride(from: 0, to: events.count, by: 2) {
            #expect(events[position] + 1 == events[position + 1])
        }
    }
}
