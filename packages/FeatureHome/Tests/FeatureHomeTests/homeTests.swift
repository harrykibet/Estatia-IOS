import Foundation
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

@Test func rejectsNonHTTPVideoSources() async throws {
    var property = PropertyModel()
    property.id = "property-43"
    property.videoUrl = ["file:///tmp/listing.mp4"]

    #expect(makeFeedPlaybackItem(from: property) == nil)
}

@Test func prefersHLSOverDirectVideoURL() async throws {
    var property = PropertyModel()
    property.id = "property-44"
    property.hlsUrl = ["https://cdn.example.test/stream.m3u8"]
    property.directVideoUrls = ["https://cdn.example.test/fallback.mp4"]
    property.videoUrl = ["https://legacy.example.test/legacy.mp4"]

    let item = makeFeedPlaybackItem(from: property)

    #expect(item?.source.url.absoluteString == "https://cdn.example.test/stream.m3u8")
}

@Test func fallsBackToDirectVideoWhenHLSIsUnavailable() async throws {
    var property = PropertyModel()
    property.id = "property-45"
    property.hlsUrl = ["file:///tmp/invalid.m3u8"]
    property.directVideoUrls = ["https://cdn.example.test/direct.mp4"]

    let item = makeFeedPlaybackItem(from: property)

    #expect(item?.source.url.absoluteString == "https://cdn.example.test/direct.mp4")
}

@Test func decodesAndroidPropertyVideoFieldsWithoutLegacyVideoURL() async throws {
    let json = Data("""
    {
      "id": "android-property-46",
      "title": "Android listing",
      "imageUrl": [],
      "directVideoUrls": ["https://cdn.example.test/direct.mp4"],
      "hlsUrl": ["https://cdn.example.test/android-stream.m3u8"],
      "video": true,
      "matchScore": 0.93,
      "createdAt": 1730000000000,
      "active": true,
      "available": true
    }
    """.utf8)

    let property = try JSONDecoder().decode(PropertyModel.self, from: json)
    let item = makeFeedPlaybackItem(from: property)

    #expect(property.videoUrl.isEmpty)
    #expect(property.matchScore == 0.93)
    #expect(property.createdAt == Date(timeIntervalSince1970: 1_730_000_000))
    #expect(item?.mediaId == "android-property-46")
    #expect(item?.matchScore == 0.93)
    #expect(item?.source.url.absoluteString == "https://cdn.example.test/android-stream.m3u8")
}
