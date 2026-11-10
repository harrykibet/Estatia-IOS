import Testing
import CoreModel

@testable import FeatureHome

@Test func feedPlaybackUsesTheFirstValidRemoteVideoURL() async throws {
    var property = PropertyModel()
    property.id = "property-123"
    property.title = "Riverside apartment"
    property.ownerName = "Listing owner"
    property.videoUrl = [
        "file:///tmp/local.mp4",
        "not a URL",
        "https://cdn.example.com/listings/property-123/master.m3u8"
    ]

    let item = makeFeedPlaybackItem(from: property)

    #expect(item?.mediaId == "property-123")
    #expect(item?.source.url.absoluteString == "https://cdn.example.com/listings/property-123/master.m3u8")
    #expect(item?.source.type == .auto)
    #expect(item?.title == "Riverside apartment")
    #expect(item?.artist == "Listing owner")
}

@Test func propertyWithoutStableIDOrRemoteVideoDoesNotAutoplay() async throws {
    var missingID = PropertyModel()
    missingID.videoUrl = ["https://cdn.example.com/video.mp4"]
    #expect(makeFeedPlaybackItem(from: missingID) == nil)

    var imageOnly = PropertyModel()
    imageOnly.id = "image-only"
    imageOnly.imageUrl = ["https://cdn.example.com/poster.jpg"]
    #expect(makeFeedPlaybackItem(from: imageOnly) == nil)

    var localOnly = PropertyModel()
    localOnly.id = "local-only"
    localOnly.videoUrl = ["file:///tmp/video.mp4"]
    #expect(makeFeedPlaybackItem(from: localOnly) == nil)
}
