import Foundation
import Testing
@testable import Core

@Suite struct PromptResolverTests {

    @Test func layersInPrecedenceOrderMostSpecificLast() throws {
        let composed = try #require(PromptResolver.composeFiling(
            global: "House style: short bodies.",
            project: "Use the ADR format.",
            callTypeBlocks: ["technical": "Code blocks for models."],
            nextCall: "Focus on the pricing discussion."))
        let globalIndex = try #require(composed.range(of: "House style")?.lowerBound)
        let projectIndex = try #require(composed.range(of: "ADR format")?.lowerBound)
        let typeIndex = try #require(composed.range(of: "Code blocks")?.lowerBound)
        let nextIndex = try #require(composed.range(of: "pricing")?.lowerBound)
        #expect(globalIndex < projectIndex)
        #expect(projectIndex < typeIndex)
        #expect(typeIndex < nextIndex)
        #expect(composed.contains("Only if you classify this call as technical"))
        #expect(composed.contains("For THIS call only"))
    }

    @Test func emptyAndWhitespaceScopesVanish() {
        #expect(PromptResolver.composeFiling(
            global: "  ", project: nil, callTypeBlocks: [:], nextCall: "\n") == nil)
        let onlyGlobal = PromptResolver.composeFiling(
            global: "Keep it short.", project: "", callTypeBlocks: [:], nextCall: nil)
        #expect(onlyGlobal == "Keep it short.")
    }

    @Test func vocabularySplitsTrimsAndDeduplicates() {
        let terms = PromptResolver.vocabularyTerms([
            "Saaa, whisper.cpp\nKA674N3P93",
            nil,
            " saaa , TapAutoStart",
        ])
        #expect(terms == ["Saaa", "whisper.cpp", "KA674N3P93", "TapAutoStart"])
    }
}

@Suite struct PromptTemplateTests {

    @Test func substitutesAllVariables() {
        let rendered = PromptTemplate.render(
            "Notes for {project} with {attendees} on {date}.",
            project: "acme", attendees: ["Jane", "Collins"],
            date: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(rendered.contains("acme"))
        #expect(rendered.contains("Jane, Collins"))
        #expect(!rendered.contains("{project}"))
        #expect(!rendered.contains("{date}"))
    }

    @Test func missingValuesFallBackToNeutralWording() {
        let rendered = PromptTemplate.render(
            "{project} / {attendees}", project: nil, attendees: [], date: .now)
        #expect(rendered == "the matched project / unknown attendees")
    }
}

@Test func presetsCoverTheShippedCallTypes() {
    #expect(PromptPreset.all.count == 3)
    #expect(Set(PromptPreset.all.map(\.callType))
        == ["client_preference", "technical", "standup"])
    for preset in PromptPreset.all {
        #expect(!preset.text.isEmpty)
    }
}
