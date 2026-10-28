import AppKit
print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")
