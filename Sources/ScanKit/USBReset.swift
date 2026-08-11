import Foundation
import IOKit
import IOUSBHost

/// Software USB re-enumeration — the programmatic equivalent of
/// unplug/replug. Used after cancelling a scan mid-pass, which leaves
/// scanners like the LiDE 110 in a wedged state.
public enum USBReset {
    /// Reset the USB device whose product/vendor name matches any of the
    /// given tokens. Acts only when exactly one device matches (safety).
    public static func resetDevice(nameTokens: [String]) -> Bool {
        let tokens = nameTokens.map { $0.lowercased() }.filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return false }

        var iter: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter
            )
                == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iter) }

        var candidates: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 {
                break
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            var matched = false
            if IORegistryEntryCreateCFProperties(
                service, &propsRef, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                let props = propsRef?.takeRetainedValue() as? [String: Any]
            {
                let name =
                    ((props["USB Product Name"] as? String ?? "") + " "
                    + (props["USB Vendor Name"] as? String ?? ""))
                    .lowercased()
                matched = tokens.contains { name.contains($0) }
            }
            if matched {
                candidates.append(service)
            } else {
                IOObjectRelease(service)
            }
        }
        defer { candidates.forEach { IOObjectRelease($0) } }
        guard candidates.count == 1 else { return false }

        do {
            let device = try IOUSBHostDevice(
                __ioService: candidates[0], options: [], queue: nil,
                interestHandler: nil
            )
            try device.reset()
            return true
        } catch {
            return false
        }
    }
}
