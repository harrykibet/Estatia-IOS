import Testing
@testable import FeatureHome
import CoreModel

@Test func mapsPropertyVideoToStablePlaybackItem() async throws {
    var property = PropertyModel()
    property.id = "property-42"
    property.title = "Modern apartment"
    property.ownerName = "Listing owner"
    property.videoUrl = [
        " ",
        "https://cdn.example.test/listing-42.m3u8"
    ]

    let item = HomeViewModel.playbackItem(for: property)

    #expect(item?.mediaId == "property-42")
    #expect(item?.source.url.absoluteString == "https://cdn.example.test/listing-42.m3u8")
    #expect(item?.title == "Modern apartment")
    #expect(item?.artist == "Listing owner")
}

@Test func doesNotCreatePlaybackItemWithoutStableIdentity() async throws {
    var property = PropertyModel()
    property.videoUrl = ["https://cdn.example.test/listing.mp4"]

    #expect(HomeViewModel.playbackItem(for: property) == nil)
}

@Test func rejectsNonHTTPVideoSources() async throws {
    var property = PropertyModel()
    property.id = "property-43"
    property.videoUrl = ["file:///tmp/listing.mp4"]

    #expect(HomeViewModel.playbackItem(for: property) == nil)
}

@Test func prefersHLSOverDirectVideoURL() async throws {
    var property = PropertyModel()
    property.id = "property-44"
    property.hlsUrl = ["https://cdn.example.test/stream.m3u8"]
    property.directVideoUrls = ["https://cdn.example.test/fallback.mp4"]
    property.videoUrl = ["https://legacy.example.test/legacy.mp4"]

    let item = HomeViewModel.playbackItem(for: property)

    #expect(item?.source.url.absoluteString == "https://cdn.example.test/stream.m3u8")
}

@Test func fallsBackToDirectVideoWhenHLSIsUnavailable() async throws {
    var property = PropertyModel()
    property.id = "property-45"
    property.hlsUrl = ["file:///tmp/invalid.m3u8"]
    property.directVideoUrls = ["https://cdn.example.test/direct.mp4"]

    let item = HomeViewModel.playbackItem(for: property)

    #expect(item?.source.url.absoluteString == "https://cdn.example.test/direct.mp4")
}
