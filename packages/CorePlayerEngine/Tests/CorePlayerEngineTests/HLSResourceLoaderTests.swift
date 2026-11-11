import XCTest
@testable import CorePlayerEngine

final class HLSResourceLoaderTests: XCTestCase {
    func testProxyURLRoundTripsHTTPSURLWithoutLosingSignedComponents() throws {
        let original = URL(
            string: "https://media.estatia.com/live/master.m3u8?token=abc&region=eu#top"
        )!

        let proxied = try XCTUnwrap(HLSResourceLoader.proxyURL(for: original))
        let restored = try XCTUnwrap(HLSResourceLoader.originURL(forProxyURL: proxied))

        XCTAssertEqual(proxied.scheme, "estatia-hls-https")
        XCTAssertEqual(proxied.host, original.host)
        XCTAssertEqual(proxied.path, original.path)
        XCTAssertEqual(proxied.query, original.query)
        XCTAssertEqual(proxied.fragment, original.fragment)
        XCTAssertEqual(restored, original)
    }

    func testProxyURLSupportsHTTPAndRejectsNonHTTPResources() throws {
        let original = URL(string: "http://media.estatia.com/master.m3u8")!
        let proxied = try XCTUnwrap(HLSResourceLoader.proxyURL(for: original))

        XCTAssertEqual(proxied.scheme, "estatia-hls-http")
        XCTAssertNil(
            HLSResourceLoader.proxyURL(
                for: URL(string: "skd://license.example/key")!
            )
        )
    }

    func testRewritesPlaylistLinesAndURIAttributesAgainstTheirOwnPlaylistURL() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",URI="audio/en.m3u8?token=audio"
        #EXT-X-KEY:METHOD=AES-128,URI="../keys/key.bin?token=key"
        #EXT-X-MAP:URI="init.mp4?sig=map"
        #EXT-X-PART:DURATION=0.2,URI="parts/part-1.m4s?sig=part"
        #EXTINF:4.0,
        segments/segment-1.m4s?sig=segment
        """
        let baseURL = URL(
            string: "https://media.estatia.com/live/master.m3u8?master=1"
        )!

        let rewritten = HLSResourceLoader.rewritePlaylist(
            playlist,
            relativeTo: baseURL
        )

        XCTAssertTrue(
            rewritten.contains(
                #"URI="estatia-hls-https://media.estatia.com/live/audio/en.m3u8?token=audio""#
            )
        )
        XCTAssertTrue(
            rewritten.contains(
                #"URI="estatia-hls-https://media.estatia.com/keys/key.bin?token=key""#
            )
        )
        XCTAssertTrue(
            rewritten.contains(
                #"URI="estatia-hls-https://media.estatia.com/live/init.mp4?sig=map""#
            )
        )
        XCTAssertTrue(
            rewritten.contains(
                #"URI="estatia-hls-https://media.estatia.com/live/parts/part-1.m4s?sig=part""#
            )
        )
        XCTAssertTrue(
            rewritten.contains(
                "estatia-hls-https://media.estatia.com/live/segments/segment-1.m4s?sig=segment"
            )
        )
        XCTAssertTrue(rewritten.contains("#EXTM3U"))
        XCTAssertTrue(rewritten.contains("#EXTINF:4.0,"))
    }

    func testRewritesContentSteeringServerURIAndLeavesNonHTTPKeySchemesAlone() {
        let playlist = """
        #EXTM3U
        #EXT-X-CONTENT-STEERING:SERVER-URI="https://control.estatia.com/steering.json?token=steer"
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://license.example/key"
        #EXT-X-SESSION-DATA:DATA-ID="com.example",URI="data:text/plain;base64,SGVsbG8="
        """
        let baseURL = URL(string: "https://media.estatia.com/master.m3u8")!

        let rewritten = HLSResourceLoader.rewritePlaylist(
            playlist,
            relativeTo: baseURL
        )

        XCTAssertTrue(
            rewritten.contains(
                #"SERVER-URI="estatia-hls-https://control.estatia.com/steering.json?token=steer""#
            )
        )
        XCTAssertTrue(rewritten.contains(#"URI="skd://license.example/key""#))
        XCTAssertTrue(
            rewritten.contains(
                #"URI="data:text/plain;base64,SGVsbG8=""#
            )
        )
    }

    func testDoesNotRewriteNonPlaylistText() {
        let text = "not an HLS playlist\nsegment.ts"
        let url = URL(string: "https://media.estatia.com/master.m3u8")!

        XCTAssertEqual(
            HLSResourceLoader.rewritePlaylist(text, relativeTo: url),
            text
        )
    }

    func testOnlyEstatiaHostedHLSIsIntercepted() {
        let estatia = MediaSource(
            url: URL(string: "https://media.estatia.com/master.m3u8")!,
            type: .hls
        )
        let thirdParty = MediaSource(
            url: URL(string: "https://video.example.net/master.m3u8")!,
            type: .hls
        )
        let progressive = MediaSource(
            url: URL(string: "https://media.estatia.com/video.mp4")!,
            type: .progressive
        )

        XCTAssertTrue(HLSResourceLoader.supports(estatia))
        XCTAssertFalse(HLSResourceLoader.supports(thirdParty))
        XCTAssertFalse(HLSResourceLoader.supports(progressive))
    }

    func testAuthorizationHeadersStayWithinEstatiaCDNNetwork() {
        let root = MediaSource(
            url: URL(string: "https://media.estatia.com/master.m3u8")!,
            type: .hls,
            headers: ["Authorization": "Bearer private-token"]
        )
        let estatiaCDN = URL(
            string: "https://backupcdn.estatia.com/segment-1.ts"
        )!
        let thirdParty = URL(
            string: "https://video-cdn.example.net/segment-1.ts"
        )!

        let internalRequest = HLSResourceLoader.requestSource(
            for: estatiaCDN,
            rootSource: root
        )
        let externalRequest = HLSResourceLoader.requestSource(
            for: thirdParty,
            rootSource: root
        )

        XCTAssertEqual(
            internalRequest.headers?["Authorization"],
            "Bearer private-token"
        )
        XCTAssertNil(externalRequest.headers)
    }
}
