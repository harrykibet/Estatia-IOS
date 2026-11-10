import XCTest
@testable import CorePlayerEngine

final class StreamingCodecNegotiatorTests: XCTestCase {
    func testAV1IsPreferredAndAllSupportedCodecsAreAdvertised() throws {
        let negotiator = StreamingCodecNegotiator(
            capabilities: StreamCodecCapabilities(
                supportsAV1: true,
                supportsHEVC: true,
                supportsDolbyVision: true
            )
        )
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/watch/master.m3u8?token=abc")!
        )

        let result = negotiator.negotiate(source)
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, "abc")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "codec" })?.value, "av1")
        XCTAssertEqual(result.headers?["X-Estatia-Capabilities"], "av1,hevc,dolbyvision")
    }

    func testHEVCIsSelectedWhenAV1IsUnavailable() throws {
        let negotiator = StreamingCodecNegotiator(
            capabilities: StreamCodecCapabilities(
                supportsAV1: false,
                supportsHEVC: true,
                supportsDolbyVision: false
            )
        )
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/video/master.m3u8")!
        )

        let result = negotiator.negotiate(source)
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "codec" })?.value, "hevc")
        XCTAssertEqual(result.headers?["X-Estatia-Capabilities"], "hevc")
    }

    func testCallerSpecifiedCodecAndCapabilitiesArePreserved() throws {
        let negotiator = StreamingCodecNegotiator(
            capabilities: StreamCodecCapabilities(
                supportsAV1: true,
                supportsHEVC: true,
                supportsDolbyVision: false
            )
        )
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/video.m3u8?codec=baseline&token=abc")!,
            headers: [
                "Authorization": "Bearer test-token",
                "x-estatia-capabilities": "h264"
            ]
        )

        let result = negotiator.negotiate(source)
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(
            components.queryItems?.filter { $0.name == "codec" }.count,
            1
        )
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "codec" })?.value, "baseline")
        XCTAssertEqual(result.headers?["Authorization"], "Bearer test-token")
        XCTAssertEqual(result.headers?["x-estatia-capabilities"], "h264")
        XCTAssertNil(result.headers?["X-Estatia-Capabilities"])
    }

    func testExternalMediaURLIsNotRewrittenOrGivenEstatiaHeaders() {
        let negotiator = StreamingCodecNegotiator(
            capabilities: StreamCodecCapabilities(
                supportsAV1: true,
                supportsHEVC: true,
                supportsDolbyVision: true
            )
        )
        let source = MediaSource(
            url: URL(string: "https://video.example.net/watch/master.m3u8?token=abc")!,
            headers: ["Authorization": "Bearer test-token"]
        )

        let result = negotiator.negotiate(source)

        XCTAssertEqual(result.url, source.url)
        XCTAssertEqual(result.headers, source.headers)
    }

    func testNoAdvancedCodecKeepsBackendDefaultRendition() throws {
        let negotiator = StreamingCodecNegotiator(
            capabilities: StreamCodecCapabilities(
                supportsAV1: false,
                supportsHEVC: false,
                supportsDolbyVision: false
            )
        )
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/video/master.m3u8")!
        )

        let result = negotiator.negotiate(source)
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false
            )
        )

        XCTAssertNil(components.queryItems?.first(where: { $0.name == "codec" }))
        XCTAssertNil(result.headers)
    }

    func testHostSuffixMustBeARealEstatiaSubdomain() {
        let negotiator = StreamingCodecNegotiator(
            capabilities: StreamCodecCapabilities(
                supportsAV1: true,
                supportsHEVC: false,
                supportsDolbyVision: false
            )
        )
        let source = MediaSource(
            url: URL(string: "https://notestatia.com/video.m3u8")!
        )

        let result = negotiator.negotiate(source)
        XCTAssertEqual(result.url, source.url)
        XCTAssertNil(result.headers)
    }
}
