import Foundation
import Network

enum NetworkInfo {
    static func isValidIPv4(_ ip: String) -> Bool {
        var addr = in_addr()
        return ip.withCString { cStr in inet_pton(AF_INET, cStr, &addr) } == 1
    }

    static func localIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                // Prefer Wi‑Fi (en0). If not available, take first non-loopback.
                let name = String(cString: interface.ifa_name)
                let flags = Int32(interface.ifa_flags)
                let isUp = (flags & IFF_UP) != 0
                let isLoopback = (flags & IFF_LOOPBACK) != 0
                if isUp && !isLoopback {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let saLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                    if getnameinfo(interface.ifa_addr, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if name == "en0" { return ip }
                        if address == nil { address = ip }
                    }
                }
            }
            if let next = interface.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        return address
    }
}

