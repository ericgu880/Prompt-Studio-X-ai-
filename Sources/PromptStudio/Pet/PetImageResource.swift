import AppKit
import Foundation

enum PetImageResource {
    static func load(from url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    static func desktopPet(in bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: "desktop-pet", withExtension: "png") else {
            return nil
        }
        return load(from: url)
    }

    static func desktopPet() -> NSImage? {
        #if SWIFT_PACKAGE
        if let image = desktopPet(in: .module) {
            return image
        }
        #endif
        return desktopPet(in: .main)
    }
}
