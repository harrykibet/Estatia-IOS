//
//  property.swift
//  model
//
//  Created by builder on 5/3/25.
//
import Foundation

public struct PropertyModel: Codable, Identifiable, Sendable {
    public var id: String?
    public var title: String?
    public var description: String?
    public var price: Double?
    public var imageUrl: [String]
    public var videoUrl: [String]
    /// Additional backend media fields used by the Android property feed.
    public var directVideoUrls: [String]?
    public var hlsUrl: [String]?
    public var video: Bool
    public var matchScore: Double
    public var latitude: Double?
    public var longitude: Double?
    public var createdAt: Date?
    public var ownerId: String?
    public var ownerName: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var county: String?
    public var active: Bool
    public var viewsCount: Int?
    public var propertyType: String?
    public var bedrooms: Int?
    public var bathrooms: Int?
    public var areaSize: Double?
    public var amenities: [String]?
    public var features: String?
    public var depositAmount: Double?
    public var address: String?
    public var availableFrom: String?
    public var leaseTerms: String?
    public var available: Bool
    
    private enum CodingKeys: String, CodingKey {
        case id, title, description, price, imageUrl, videoUrl
        case directVideoUrls, hlsUrl, video, matchScore, latitude, longitude, createdAt
        case ownerId, ownerName, contactPhone, contactEmail, county, active
        case viewsCount, propertyType, bedrooms, bathrooms, areaSize
        case amenities, features, depositAmount, address, availableFrom
        case leaseTerms, available
    }

    public init() {
        self.id = nil
        self.title = nil
        self.description = nil
        self.price = nil
        self.imageUrl = []
        self.videoUrl = []
        self.directVideoUrls = nil
        self.hlsUrl = nil
        self.video = false
        self.matchScore = 0.5
        self.latitude = nil
        self.longitude = nil
        self.createdAt = nil
        self.ownerId = nil
        self.ownerName = nil
        self.contactPhone = nil
        self.contactEmail = nil
        self.county = nil
        self.active = false
        self.viewsCount = nil
        self.propertyType = nil
        self.bedrooms = nil
        self.bathrooms = nil
        self.areaSize = nil
        self.amenities = nil
        self.features = nil
        self.depositAmount = nil
        self.address = nil
        self.availableFrom = nil
        self.leaseTerms = nil
        self.available = false
    }
    
    /// Decodes the Android property-feed shape while remaining compatible with
    /// older records that only contain the legacy iOS fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        price = try container.decodeIfPresent(Double.self, forKey: .price)
        imageUrl = try container.decodeIfPresent([String].self, forKey: .imageUrl) ?? []
        videoUrl = try container.decodeIfPresent([String].self, forKey: .videoUrl) ?? []
        directVideoUrls = try container.decodeIfPresent([String].self, forKey: .directVideoUrls)
        hlsUrl = try container.decodeIfPresent([String].self, forKey: .hlsUrl)
        video = try container.decodeIfPresent(Bool.self, forKey: .video) ?? false
        matchScore = try container.decodeIfPresent(Double.self, forKey: .matchScore) ?? 0.5
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)

        if let milliseconds = try? container.decode(Int64.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        } else if let decodedDate = try? container.decode(Date.self, forKey: .createdAt) {
            createdAt = decodedDate
        } else {
            createdAt = nil
        }

        ownerId = try container.decodeIfPresent(String.self, forKey: .ownerId)
        ownerName = try container.decodeIfPresent(String.self, forKey: .ownerName)
        contactPhone = try container.decodeIfPresent(String.self, forKey: .contactPhone)
        contactEmail = try container.decodeIfPresent(String.self, forKey: .contactEmail)
        county = try container.decodeIfPresent(String.self, forKey: .county)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        viewsCount = try container.decodeIfPresent(Int.self, forKey: .viewsCount)
        propertyType = try container.decodeIfPresent(String.self, forKey: .propertyType)
        bedrooms = try container.decodeIfPresent(Int.self, forKey: .bedrooms)
        bathrooms = try container.decodeIfPresent(Int.self, forKey: .bathrooms)
        areaSize = try container.decodeIfPresent(Double.self, forKey: .areaSize)
        amenities = try container.decodeIfPresent([String].self, forKey: .amenities)
        features = try container.decodeIfPresent(String.self, forKey: .features)
        depositAmount = try container.decodeIfPresent(Double.self, forKey: .depositAmount)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        availableFrom = try container.decodeIfPresent(String.self, forKey: .availableFrom)
        leaseTerms = try container.decodeIfPresent(String.self, forKey: .leaseTerms)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
    }
}
