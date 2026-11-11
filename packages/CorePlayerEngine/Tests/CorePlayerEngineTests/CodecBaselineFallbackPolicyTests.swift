import XCTest
@testable import CorePlayerEngine

final class CodecBaselineFallbackPolicyTests: XCTestCase {
    func testReplacesSelectedCodecAndPreservesOtherURLAndRequestData() throws {
        let metadata = Metadata(
            title: "Fallback video",
            artist: "Estatia"
        )
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/watch/master.m3u8?token=abc&codec=av1&quality=auto#video")!,
            type: .hls,
            headers: [
                "Authorization": "Bearer test-token",
                "X-Estatia-Capabilities": "av1,hevc"
            ],
            metadata: metadata
        )

        let result = try XCTUnwrap(
            CodecBaselineFallbackPolicy.fallbackSource(for: source)
        )
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.path, "/watch/master.m3u8")
        XCTAssertEqual(components.fragment, "video")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, "abc")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "quality" })?.value, "auto")
        XCTAssertEqual(
            components.queryItems?.filter { $0.name.caseInsensitiveCompare("codec") == .orderedSame }.count,
            1
        )
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "codec" })?.value, "baseline")
        XCTAssertEqual(result.headers, source.headers)
        XCTAssertEqual(result.type, source.type)
        XCTAssertEqual(result.metadata, source.metadata)
    }

    func testAddsBaselineWhenInitialSourceHasNoCodecQuery() throws {
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/video/master.m3u8?token=abc")!
        )

        let result = try XCTUnwrap(
            CodecBaselineFallbackPolicy.fallbackSource(for: source)
        )
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "codec" })?.value, "baseline")
    }

    func testDoesNotRewriteThirdPartyMedia() {
        let source = MediaSource(
            url: URL(string: "https://video.example.net/master.m3u8?codec=av1")!
        )

        XCTAssertNil(CodecBaselineFallbackPolicy.fallbackSource(for: source))
    }

    func testDoesNotRetrySourceAlreadyUsingBaseline() {
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/master.m3u8?codec=baseline")!
        )

        XCTAssertNil(CodecBaselineFallbackPolicy.fallbackSource(for: source))
    }

    func testHostSuffixMustBeARealEstatiaSubdomain() {
        let source = MediaSource(
            url: URL(string: "https://notestatia.com/master.m3u8?codec=av1")!
        )

        XCTAssertNil(CodecBaselineFallbackPolicy.fallbackSource(for: source))
    }

    func testDuplicateCodecParametersCollapseToOneBaselineParameter() throws {
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/master.m3u8?codec=av1&codec=hevc")!
        )

        let result = try XCTUnwrap(
            CodecBaselineFallbackPolicy.fallbackSource(for: source)
        )
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )
        let codecItems = components.queryItems?.filter {
            $0.name.caseInsensitiveCompare("codec") == .orderedSame
        } ?? []

        XCTAssertEqual(codecItems.count, 1)
        XCTAssertEqual(codecItems.first?.value, "baseline")
    }
}
