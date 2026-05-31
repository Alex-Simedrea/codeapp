//
//  CodeFont.swift
//  Code
//
//  Created by OpenAI on 31/05/2026.
//

import CoreText
import UIKit

enum CodeFont {
    static let sfMonoFamilyName = "SF Mono"

    private static let sfMonoFileName = "SF-Mono-Regular"
    private static let sfMonoPostScriptName = "SFMono-Regular"

    private static let aliases = [
        sfMonoFamilyName: sfMonoPostScriptName,
        "SF Mono Regular": sfMonoPostScriptName,
        sfMonoPostScriptName: sfMonoPostScriptName,
    ]

    private static var didRegisterKnownFonts = false

    static func registerKnownFonts() {
        guard !didRegisterKnownFonts else { return }
        didRegisterKnownFonts = true

        for url in knownFontURLs() {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    static func font(named name: String, size: CGFloat) -> UIFont? {
        registerKnownFonts()

        if let font = UIFont(name: name, size: size) {
            return font
        }

        if let alias = aliases[name], let font = UIFont(name: alias, size: size) {
            return font
        }

        let descriptor = UIFontDescriptor(
            fontAttributes: [UIFontDescriptor.AttributeName.family: name])
        let font = UIFont(descriptor: descriptor, size: size)
        return font.familyName == name ? font : nil
    }

    static func fontData(named name: String) -> Data? {
        guard let font = font(named: name, size: 12) else {
            return nil
        }
        return UIFont.data(from: font)
    }

    static func fontFamilyName(from descriptor: UIFontDescriptor) -> String {
        if descriptor.postscriptName == sfMonoPostScriptName
            || descriptor.object(forKey: .family) as? String == sfMonoFamilyName
        {
            return sfMonoFamilyName
        }

        return descriptor.object(forKey: .family) as? String ?? descriptor.postscriptName
    }

    static func cssLocalSources(for fontFamily: String) -> String {
        var names = [fontFamily]
        if let alias = aliases[fontFamily], alias != fontFamily {
            names.append(alias)
        }

        return names.map { #"local("\#(cssEscaped($0))")"# }.joined(
            separator: ",\n                  ")
    }

    static func webFontExtension(for fontFamily: String) -> String {
        aliases[fontFamily] == sfMonoPostScriptName ? "otf" : "ttf"
    }

    static func webFontFormat(for fontFamily: String) -> String {
        aliases[fontFamily] == sfMonoPostScriptName ? "opentype" : "truetype"
    }

    private static func knownFontURLs() -> [URL] {
        guard let bundledURL = Bundle.main.url(forResource: sfMonoFileName, withExtension: "otf")
        else { return [] }
        return [bundledURL]
    }

    private static func cssEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }
}
