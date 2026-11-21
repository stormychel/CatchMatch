//
//  generate_dmg_background.swift
//  CatchMatch
//
//  Usage, from repo root:
//    swiftc -parse-as-library Scripts/generate_dmg_background.swift -o /tmp/generate_dmg_background && /tmp/generate_dmg_background
//  Writes dmg_assets/catchmatch-dmg-background.png, which Scripts/release_to_cdn.sh picks up.
//
//  Created by Michel Storms on 15/05/2026.
//

import AppKit

@main
struct DMGBackgroundGenerator {

    static func main() {
        do {
            try run()
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let width: CGFloat = 700
        let height: CGFloat = 500
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()

        autoreleasepool {
            let topColor = NSColor(calibratedRed: 0.984, green: 0.984, blue: 0.996, alpha: 1)
            let bottomColor = NSColor(calibratedRed: 0.925, green: 0.929, blue: 0.964, alpha: 1)

            if let gradient = NSGradient(colors: [topColor, bottomColor]) {
                gradient.draw(
                    in: NSRect(origin: .zero, size: size),
                    angle: 90
                )
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let title = NSMutableAttributedString(
                string: "Drag the CatchMatch icon to the Applications folder",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
                    .paragraphStyle: paragraph
                ]
            )

            // Bold "CatchMatch"
            let appNameRange = (title.string as NSString).range(of: "CatchMatch")
            title.addAttributes(
                [.font: NSFont.systemFont(ofSize: 28, weight: .semibold)],
                range: appNameRange
            )

            // Bold "Applications"
            let applicationsRange = (title.string as NSString).range(of: "Applications")
            title.addAttributes(
                [.font: NSFont.systemFont(ofSize: 28, weight: .semibold)],
                range: applicationsRange
            )

            let titleRect = NSRect(
                x: 0,
                y: height - 90,
                width: width,
                height: 80
            )

            title.draw(in: titleRect)

            let arrows = "⇣\n⇣\n⇣"
            let arrowAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 32, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 0.9),
                .paragraphStyle: paragraph,
                .kern: 1.5
            ]

            let arrowRect = NSRect(
                x: 0,
                y: 140,
                width: width,
                height: 120
            )
            (arrows as NSString).draw(in: arrowRect, withAttributes: arrowAttributes)
        }

        image.unlockFocus()

        // Write to ../dmg_assets/catchmatch-dmg-background.png relative to this
        // script's location, so it works regardless of the current working dir.
        let scriptURL = URL(fileURLWithPath: #filePath)
        let outputURL = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("dmg_assets")
            .appendingPathComponent("catchmatch-dmg-background.png")

        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let pngData = rep.representation(using: .png, properties: [:])
        else {
            fputs("Failed to generate background\n", stderr)
            exit(1)
        }

        try pngData.write(to: outputURL)
        print("Saved background to \(outputURL.path)")
    }
}
