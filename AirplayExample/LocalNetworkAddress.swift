import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum LocalNetworkAddress
{
    static func preferredIPv4() -> String?
    {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr
        else
        {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        // Prefer Wi‑Fi (`en0`) on iPad/iPhone.
        let preferred = ["en0", "bridge0", "en1"]
        var fallback: String?

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next })
        {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { continue }
            let ip = String(cString: host)
            if ip == "127.0.0.1" { continue }

            if preferred.contains(name)
            {
                address = ip
                break
            }

            fallback = fallback ?? ip
        }

        return address ?? fallback
    }
}
