//
//  NavigationActions.swift
//  estatia
//
//  Created by builder on 5/24/26.
//

import CoreDesignSystem
import FeatureProfile
import FeatureSearch


public struct NavigationActions {
    
    // MARK: - Global Navigation
    
    public var switchTab: @MainActor (AppTabID) -> Void
    public var navigateHome: @MainActor () -> Void
    public var navigateProfile: @MainActor (ProfileDestination) -> Void
    public var navigateSearch: @MainActor (SearchDestination) -> Void
    
    // MARK: - Auth Flow (global boundary)
    
    public var authCompleted: @MainActor () -> Void
}
