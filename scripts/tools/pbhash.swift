// Prints a hash of every type of every item on the general pasteboard (content never printed).
import AppKit
import CryptoKit
var hasher = SHA256()
for item in NSPasteboard.general.pasteboardItems ?? [] {
    for type in item.types.sorted(by: { $0.rawValue < $1.rawValue }) {
        hasher.update(data: Data(type.rawValue.utf8))
        hasher.update(data: item.data(forType: type) ?? Data())
    }
}
print(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
