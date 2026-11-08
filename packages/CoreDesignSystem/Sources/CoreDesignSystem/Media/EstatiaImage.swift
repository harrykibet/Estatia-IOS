//
//  EstatiaImage.swift
//  CoreDesignSystem
//
//  Created by builder on 4/12/26.
//

import SwiftUI

public struct EstatiaImage: View {

    private let image: Image
    private let contentMode: ContentMode

    public init(
        image: Image,
        contentMode: ContentMode = .fill
    ) {
        self.image = image
        self.contentMode = contentMode
    }

    /// Creates an image from an asset in the host application's main bundle.
    ///
    /// Feature modules use this initializer for app-owned assets such as the
    /// application logo. Package-owned assets should use the image initializer
    /// with an explicitly constructed Image from the appropriate bundle.
    public init(
        name: String,
        contentMode: ContentMode = .fill
    ) {
        self.image = Image(name)
        self.contentMode = contentMode
    }

    public var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .clipped()
    }
}
