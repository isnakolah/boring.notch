//
//  SweepFormatting.swift
//  boringNotch
//

import Foundation

/// How Sweep says a size.
///
/// One function rather than one per view: the pane and the confirmation sheet it
/// presents both quote the same figures, and a plan that reads "1.2 GB" in the
/// pane and "1,234 MB" in the sheet asking you to confirm it is not reassuring.
func sweepFormatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
