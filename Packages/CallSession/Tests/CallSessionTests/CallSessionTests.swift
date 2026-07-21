import Testing
@testable import CallSession

@Test func moduleLinksAndReportsIdentity() {
    #expect(CallSessionModule.name == "CallSession")
}
