import Foundation
import Testing
@testable import AndesiteCore

@Test func yamlFrontmatterTypedPropertiesAndNestedTags() throws {
    let source = """
    ---
    title: "true"
    count: 42
    ratio: 3.14
    favorite: true
    created: 2026-11-08
    updated: 2026-11-08T12:30:00
    link: "[[A note]]"
    aliases: ["봄", "Spring"]
    tags:
      - Project/Work
      - 한국어/메모
    description: |
      Multi-line:
        indented text
    ---
    # Hello #inbox/to-read #PROJECT/work
    `#ignore-in-code`
    ```md
    #ignored/fence
    ```
    Just #한글 and #1984 and #y1984.
    [text](https://site.example/#fragment)
    <!-- #hidden -->
    escaped \\#not-a-tag
    """
    let result = try ObsidianMetadataParser.parse(Data(source.utf8))
    #expect(result.state == "valid")
    #expect(result.diagnostic == nil)
    func property(_ name: String) -> [String: Any]? {
        result.properties.first { $0["name"] as? String == name }
    }
    #expect(property("title")?["type"] as? String == "text")
    #expect(property("title")?["value"] as? String == "true")
    #expect(property("count")?["type"] as? String == "number")
    #expect(property("count")?["value"] as? Int64 == 42)
    #expect(property("ratio")?["type"] as? String == "number")
    #expect(property("favorite")?["type"] as? String == "checkbox")
    #expect(property("favorite")?["value"] as? Bool == true)
    #expect(property("created")?["type"] as? String == "date")
    #expect(property("updated")?["type"] as? String == "datetime")
    #expect((property("description")?["value"] as? String)?.contains("Multi-line:\n  indented text") == true)
    #expect(property("aliases")?["type"] as? String == "list")
    #expect(property("tags")?["type"] as? String == "tags")
    #expect(result.tags.contains { $0.canonical == "project/work" && $0.origin == "frontmatter" })
    #expect(result.tags.contains { $0.canonical == "project/work" && $0.origin == "inline" })
    #expect(result.tags.contains { $0.canonical == "한국어/메모" })
    #expect(result.tags.contains { $0.canonical == "inbox/to-read" })
    #expect(result.tags.contains { $0.canonical == "한글" })
    #expect(result.tags.contains { $0.canonical == "y1984" })
    #expect(!result.tags.contains { $0.canonical == "1984" })
    #expect(!result.tags.contains { $0.canonical.contains("ignored") || $0.canonical.contains("fragment") ||
        $0.canonical.contains("hidden") || $0.canonical.contains("not-a-tag") })
}

@Test func yamlJSONFrontmatterAndFlowListsAreSupported() throws {
    let text = """
    ---
    {"tags": ["coding", "dev/Rust"], "publish": false, "rating": 5, "people": ["A", "B"]}
    ---
    # Notes
    """
    let result = try ObsidianMetadataParser.parse(Data(text.utf8))
    #expect(result.state == "valid")
    #expect(result.tags.count == 2)
    #expect(result.properties.contains { $0["name"] as? String == "publish" &&
        $0["type"] as? String == "checkbox" })
    #expect(result.scalars.contains { $0.property == "people" && $0.text == "A" })
}

@Test func malformedYAMLDoesNotCreatePhantomPropertyTags() throws {
    let text = """
    ---
    tags: [valid, broken
    favorite: true
    ---
    #only-inline
    """
    let result = try ObsidianMetadataParser.parse(Data(text.utf8))
    #expect(result.state == "invalid")
    #expect(!result.properties.isEmpty == false)
    #expect(result.tags.map(\.canonical) == ["only-inline"])
    let unfinished = try ObsidianMetadataParser.parse(Data("""
    ---
    tags:
      - phantom
    """.utf8))
    #expect(unfinished.state == "invalid")
    #expect(unfinished.tags.isEmpty)
}

@Test func tagNormalizationAndReservedSyntaxFollowsObsidian() {
    #expect(ObsidianMetadataParser.canonicalTag("#TaG/Nested") == "tag/nested")
    #expect(ObsidianMetadataParser.canonicalTag("#태그/한글") == "태그/한글")
    #expect(ObsidianMetadataParser.canonicalTag("#1984") == nil)
    #expect(ObsidianMetadataParser.canonicalTag("#x1984") == "x1984")
    #expect(ObsidianMetadataParser.canonicalTag("a b") == nil)
    #expect(ObsidianMetadataParser.canonicalTag("/a") == nil)
    #expect(ObsidianMetadataParser.canonicalTag("a//b") == nil)
}

@Test func emptyPropertiesEmojiAndQuotedCodeAreHandledConservatively() throws {
    let source = """
    ---
    tags:
    aliases: []
    empty: null
    text: "tag:#not-an-inline-tag"
    ---
    > ```md
    > #false-in-blockquoted-fence
    > ```
    <span data-tag="#false-in-html">real #visible</span>
    ## Heading #nested/태그
      - list #nested/children
    #🚀/launch #🏳️‍🌈/pride
    """
    let result = try ObsidianMetadataParser.parse(Data(source.utf8))
    #expect(result.state == "valid")
    let tags = Set(result.tags.map(\.canonical))
    #expect(tags.contains("visible"))
    #expect(tags.contains("nested/태그"))
    #expect(tags.contains("nested/children"))
    #expect(tags.contains("🚀/launch"))
    #expect(tags.contains("🏳️‍🌈/pride"))
    #expect(!tags.contains(where: { $0.hasPrefix("false") || $0.contains("not-an-inline") }))
}
