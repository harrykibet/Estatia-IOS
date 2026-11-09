//
//  DarkColors.swift
//  CoreDesignSystem
//
//  Created by builder on 4/4/26.
//
//  Dark theme semantic colors — mirrors the Material 3 role structure.

import SwiftUI

public extension AppSemanticColors {

    @MainActor static let dark = AppSemanticColors(
        // Primary
        primary: ColorPalette.Blue.blue80,
        onPrimary: ColorPalette.Blue.blue20,
        primaryContainer: ColorPalette.Blue.blue30,
        onPrimaryContainer: ColorPalette.Blue.blue90,

        // Secondary
        secondary: ColorPalette.Slate.slate80,
        onSecondary: ColorPalette.Slate.slate30,
        secondaryContainer: ColorPalette.Slate.slate30,
        onSecondaryContainer: ColorPalette.Slate.slate90,

        // Tertiary
        tertiary: ColorPalette.Orange.orange80,
        onTertiary: ColorPalette.Orange.orange20,
        tertiaryContainer: ColorPalette.Orange.orange30,
        onTertiaryContainer: ColorPalette.Orange.orange90,

        // Error
        error: ColorPalette.Red.red80,
        onError: ColorPalette.Red.red20,
        errorContainer: ColorPalette.Red.red30,
        onErrorContainer: ColorPalette.Red.red90,

        // Surfaces
        background: ColorPalette.Slate.slate10,
        onBackground: ColorPalette.Slate.slate90,
        surface: ColorPalette.Slate.slate10,
        onSurface: ColorPalette.Slate.slate90,
        surfaceVariant: ColorPalette.Slate.slate30,
        onSurfaceVariant: ColorPalette.Slate.slate80,

        // Inverse
        inverseSurface: ColorPalette.Slate.slate90,
        inverseOnSurface: ColorPalette.Slate.slate20,

        // Outline & disabled
        outline: ColorPalette.Slate.slate60,
        disabled: ColorPalette.Slate.slate40,

        // Text
        textPrimary: ColorPalette.Slate.slate99,
        textSecondary: ColorPalette.Slate.slate70,
        textDisabled: ColorPalette.Slate.slate50,

        // Status
        success: ColorPalette.Green.green80,
        warning: ColorPalette.Orange.orange80,
        info: ColorPalette.Blue.blue80,

        // Feedback
        progressBackground: ColorPalette.Slate.slate40.opacity(0.35),
        progressFill: ColorPalette.Blue.blue80,
        separator: ColorPalette.Slate.slate30.opacity(0.6)
    )
}
