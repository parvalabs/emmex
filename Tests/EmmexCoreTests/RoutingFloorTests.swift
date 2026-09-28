import Testing
@testable import EmmexCore

@Suite struct RoutingFloorTests {
    @Test func judgmentCuesForceFrontier() {
        let r = RoutingFloor.minimumTier(for: "There is a race in AppController when select() runs during load")
        #expect(r?.0 == .frontier)
    }
    @Test func multiStepEditIsAtLeastCheap() {
        #expect(RoutingFloor.minimumTier(for: "Fix the typo in README.md and then run the tests")?.0 == .cheap)
    }
    @Test func codeQuestionIsAtLeastCheap() {
        #expect(RoutingFloor.minimumTier(for: "What does SessionStore do?")?.0 == .cheap)
    }
    @Test func smallTalkHasNoFloor() {
        #expect(RoutingFloor.minimumTier(for: "hi there") == nil)
        #expect(RoutingFloor.minimumTier(for: "thanks!") == nil)
    }
    @Test func floorNeverLowersADecision() {
        let d = RouteDecision(tier: .frontier, reason: "x", confidence: 0.9, router: "test")
        #expect(RoutingFloor.apply(d, prompt: "hi").tier == .frontier)
    }
    @Test func affirmationInheritsPreviousTierButNeverLocal() {
        #expect(RoutingFloor.continuation(prompt: "yes", previous: .local)?.0 == .cheap)
        #expect(RoutingFloor.continuation(prompt: "Yes, please.", previous: .frontier)?.0 == .frontier)
        #expect(RoutingFloor.continuation(prompt: "ok go ahead", previous: nil)?.0 == .cheap)
    }
    @Test func backReferenceCountsAsContinuation() {
        #expect(RoutingFloor.continuation(prompt: "I'm answering yes to your previous question", previous: .local)?.0 == .cheap)
    }
    @Test func standaloneRequestsAreNotContinuations() {
        #expect(RoutingFloor.continuation(prompt: "what is this project about?", previous: .frontier) == nil)
        #expect(RoutingFloor.continuation(prompt: "yes, and also rename the module and update every import", previous: .cheap) == nil)
    }
}
