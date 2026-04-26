import CryptoKit
import Foundation

struct ImageProxyConfiguration: Equatable {
    let baseURL: URL
    let signingSecret: String?

    var origin: String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.absoluteString
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        var origin = (components.url ?? baseURL).absoluteString
        if origin.hasSuffix("/") {
            origin.removeLast()
        }
        return origin
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = nil,
        userDefaults: UserDefaults? = nil
    ) -> ImageProxyConfiguration? {
        let bundleInfo = infoDictionary ?? Bundle.main.infoDictionary ?? [:]
        let configuredValue = userDefaults.flatMap { AppPreferences.imageProxyBaseURL(defaults: $0) }
        let fallbackValue = trimmedEnvironmentValue(
            for: "INBOX_ZERO_IMAGE_PROXY_BASE_URL",
            environment: environment
        ) ?? trimmedEnvironmentValue(
            for: "NEXT_PUBLIC_IMAGE_PROXY_BASE_URL",
            environment: environment
        ) ?? resolvedBundleSettingValue(
            for: "InboxZeroImageProxyBaseURL",
            infoDictionary: bundleInfo
        )
        let signingSecret = trimmedEnvironmentValue(
            for: "INBOX_ZERO_IMAGE_PROXY_SIGNING_SECRET",
            environment: environment
        ) ?? trimmedEnvironmentValue(
            for: "IMAGE_PROXY_SIGNING_SECRET",
            environment: environment
        ) ?? resolvedBundleSettingValue(
            for: "InboxZeroImageProxySigningSecret",
            infoDictionary: bundleInfo
        )

        if let configuredValue,
           let configuration = normalized(from: configuredValue, signingSecret: signingSecret) {
            return configuration
        }

        let rawValue = fallbackValue
        if let rawValue {
            if disabledEnvironmentValues.contains(rawValue.lowercased()) {
                return nil
            }
            return normalized(from: rawValue, signingSecret: signingSecret)
        }

        return normalized(from: "img.getinboxzero.com", signingSecret: signingSecret)
    }

    static func normalized(from rawValue: String, signingSecret: String? = nil) -> ImageProxyConfiguration? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              host.isEmpty == false
        else {
            return nil
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/proxy"
        }

        guard let normalizedURL = components.url else { return nil }
        return ImageProxyConfiguration(
            baseURL: normalizedURL,
            signingSecret: trimmedSigningSecret(signingSecret)
        )
    }

    func proxiedAssetURL(for assetURLString: String, now: Date = Date()) -> String {
        let trimmedValue = assetURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedAssetURL = decodeHTMLURLValue(trimmedValue)

        guard let assetComponents = URLComponents(string: decodedAssetURL),
              let scheme = assetComponents.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return assetURLString
        }

        guard isProxyEndpoint(assetComponents) == false else {
            return assetURLString
        }

        guard var proxyComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return assetURLString
        }

        let encodedAssetURL = percentEncodedQueryValue(decodedAssetURL)
        var queryComponents: [String] = []

        if let existingQuery = proxyComponents.percentEncodedQuery,
           existingQuery.isEmpty == false {
            queryComponents.append(existingQuery)
        }

        queryComponents.append("u=\(encodedAssetURL)")

        if let signingSecret {
            let expiresAt = ImageProxyConfiguration.expiresAt(now: now)
            let signature = signAssetProxyRequest(
                assetURL: decodedAssetURL,
                expiresAt: expiresAt,
                signingSecret: signingSecret
            )
            queryComponents.append("e=\(expiresAt)")
            queryComponents.append("s=\(signature)")
        }

        proxyComponents.percentEncodedQuery = queryComponents.joined(separator: "&")

        return proxyComponents.url?.absoluteString ?? assetURLString
    }

    private func isProxyEndpoint(_ urlComponents: URLComponents) -> Bool {
        guard let proxyComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }

        return urlComponents.scheme?.lowercased() == proxyComponents.scheme?.lowercased()
            && urlComponents.host?.lowercased() == proxyComponents.host?.lowercased()
            && urlComponents.port == proxyComponents.port
            && urlComponents.path == proxyComponents.path
    }

    private static func trimmedEnvironmentValue(
        for key: String,
        environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else {
            return nil
        }
        return value
    }

    private static func resolvedBundleSettingValue(
        for key: String,
        infoDictionary: [String: Any]
    ) -> String? {
        guard let value = infoDictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard trimmed.hasPrefix("$(") == false else { return nil }
        return trimmed
    }

    private static func trimmedSigningSecret(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func expiresAt(now: Date) -> Int {
        Int(floor(now.timeIntervalSince1970)) + defaultSignedAssetProxyTTLSeconds
    }

    private func signAssetProxyRequest(
        assetURL: String,
        expiresAt: Int,
        signingSecret: String
    ) -> String {
        let payload = Data("\(expiresAt):\(assetURL)".utf8)
        let key = SymmetricKey(data: Data(signingSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(signature).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let disabledEnvironmentValues: Set<String> = [
        "0",
        "false",
        "off",
        "disabled",
        "none",
    ]

    private static let defaultSignedAssetProxyTTLSeconds = 5 * 60
}

private func decodeHTMLURLValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&#38;", with: "&")
        .replacingOccurrences(of: "&#x26;", with: "&")
        .replacingOccurrences(of: "&#X26;", with: "&")
}

private func percentEncodedQueryValue(_ value: String) -> String {
    let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
}
