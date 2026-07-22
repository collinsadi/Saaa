import Testing
@testable import Core

@Suite struct HubOpacityPolicyTests {

    @Test func clampsToTheLegibilityFloorAndCeiling() {
        #expect(HubOpacityPolicy.effective(
            userOpacity: 0.05, reduceTransparency: false,
            isInactive: false, fadeWhenInactive: false) == HubOpacityPolicy.floor)
        #expect(HubOpacityPolicy.effective(
            userOpacity: 1.7, reduceTransparency: false,
            isInactive: false, fadeWhenInactive: false) == 1)
    }

    @Test func reduceTransparencyAlwaysWins() {
        #expect(HubOpacityPolicy.effective(
            userOpacity: 0.4, reduceTransparency: true,
            isInactive: true, fadeWhenInactive: true) == 1)
    }

    @Test func inactiveFadeIsOptInAndFloored() {
        #expect(HubOpacityPolicy.effective(
            userOpacity: 0.8, reduceTransparency: false,
            isInactive: true, fadeWhenInactive: true) == 0.65)
        #expect(HubOpacityPolicy.effective(
            userOpacity: 0.8, reduceTransparency: false,
            isInactive: true, fadeWhenInactive: false) == 0.8)
        #expect(HubOpacityPolicy.effective(
            userOpacity: 0.35, reduceTransparency: false,
            isInactive: true, fadeWhenInactive: true) == HubOpacityPolicy.floor)
    }
}
