//
//  AppIcons.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 16/08/24.
//

import SwiftUI
import AppKit

struct AppIcons {
    
    func getIcon(file path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path)
        else { return nil }
        
        return NSWorkspace.shared.icon(forFile: path)
    }
    
    func getIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        )?.absoluteString
        else { return nil }
        
        return getIcon(file: path)
    }
    
        /// Easily read Info.plist as a Dictionary from any bundle by accessing .infoDictionary on Bundle
    func bundle(forBundleID: String) -> Bundle? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: forBundleID)
        else { return nil }
        
        return Bundle(url: url)
    }
    
}

func AppIcon(for bundleID: String) -> Image {
    let workspace = NSWorkspace.shared
    
    if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        return Image(nsImage: appIcon)
    }
    
    return Image(nsImage: workspace.icon(for: .applicationBundle))
}


/// The user-facing display name of an installed app, looked up by bundle identifier.
func AppName(for bundleID: String) -> String? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
    }
    if let info = Bundle(url: appURL)?.infoDictionary,
       let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String),
       !name.isEmpty {
        return name
    }
    return FileManager.default.displayName(atPath: appURL.path)
        .replacingOccurrences(of: ".app", with: "")
}

func AppIconAsNSImage(for bundleID: String) -> NSImage? {
    let workspace = NSWorkspace.shared
    
    if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        appIcon.size = NSSize(width: 256, height: 256)
        return appIcon
    }
    return nil
}

