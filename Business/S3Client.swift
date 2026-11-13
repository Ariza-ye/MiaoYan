import CryptoKit
import Foundation

struct S3Configuration: Codable, Equatable, Sendable {
    var endpoint: String
    var region: String
    var bucket: String
    var prefix: String
    var accessKey: String

    var objectPrefix: String {
        let value = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.isEmpty ? "" : value + "/"
    }

    func validate() throws {
        guard let url = URLComponents(string: endpoint),
            let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
            !bucket.isEmpty, !bucket.contains("/"), !region.isEmpty, !accessKey.isEmpty,
            !objectPrefix.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw S3Error.invalidConfiguration }
    }
}

enum S3Error: Error, LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case requestFailed(Int, String)
    case unsafePath(String)
    case changed(String)
    case unavailable(String)
    case unsupportedConditions

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Invalid S3 settings. Use an HTTPS endpoint and fill in the bucket, region and access key."
        case .invalidResponse: return "The S3 server returned an invalid response."
        case .requestFailed(let status, let code): return "S3 request failed (HTTP \(status)\(code.isEmpty ? "" : ", \(code)"))."
        case .unsafePath(let path): return "The S3 object has an unsafe path: \(path)"
        case .changed(let path): return "The file changed during sync: \(path)"
        case .unavailable(let path): return "The file or folder could not be read: \(path)"
        case .unsupportedConditions: return "This S3 service does not enforce conditional writes. Sync cannot safely use it."
        }
    }
}

protocol S3ObjectStore: Sendable {
    func list() async throws -> [String: String]
    func get(_ key: String, matching etag: String) async throws -> Data
    func put(_ key: String, data: Data, matching etag: String?) async throws -> String
    func delete(_ key: String, matching etag: String) async throws
}

struct S3Client: S3ObjectStore {
    let configuration: S3Configuration
    let secret: String

    func list() async throws -> [String: String] {
        var objects: [String: String] = [:]
        var token: String?
        repeat {
            var query = ["list-type": "2", "encoding-type": "url", "prefix": configuration.objectPrefix]
            if let token { query["continuation-token"] = token }
            let (data, _) = try await request("GET", query: query)
            let page = try S3ListParser.parse(data)
            for (key, etag) in page.objects {
                guard key.hasPrefix(configuration.objectPrefix) else { throw S3Error.invalidResponse }
                let relative = String(key.dropFirst(configuration.objectPrefix.count))
                if !relative.isEmpty && !relative.hasSuffix("/") {
                    guard objects.updateValue(etag, forKey: relative) == nil else { throw S3Error.invalidResponse }
                }
            }
            if page.truncated {
                guard let next = page.nextToken, !next.isEmpty, next != token else { throw S3Error.invalidResponse }
                token = next
            } else {
                token = nil
            }
        } while token != nil
        return objects
    }

    func get(_ key: String, matching etag: String) async throws -> Data {
        try await request("GET", key: key, headers: ["if-match": etag]).0
    }

    func put(_ key: String, data: Data, matching etag: String?) async throws -> String {
        let condition = etag.map { ["if-match": $0] } ?? ["if-none-match": "*"]
        let (_, response) = try await request("PUT", key: key, headers: condition, body: data)
        guard let result = response.value(forHTTPHeaderField: "ETag"), !result.isEmpty else { throw S3Error.invalidResponse }
        return result
    }

    func delete(_ key: String, matching etag: String) async throws {
        _ = try await request("DELETE", key: key, headers: ["if-match": etag])
    }

    func verifyConditionalWrites() async throws {
        _ = try await list()
        let key = ".miaoyan-sync/probes/\(UUID().uuidString)"
        let etag = try await put(key, data: Data("probe".utf8), matching: nil)
        do {
            try await expectRejectedPut(key, etag: nil)
            try await expectRejectedPut(key, etag: "\"not-the-current-etag\"")
        } catch {
            try? await delete(key, matching: etag)
            throw error
        }
        try? await delete(key, matching: etag)
    }

    private func expectRejectedPut(_ key: String, etag: String?) async throws {
        do {
            _ = try await put(key, data: Data("collision".utf8), matching: etag)
        } catch S3Error.requestFailed(let status, _) where status == 409 || status == 412 {
            return
        }
        throw S3Error.unsupportedConditions
    }

    func signedRequest(
        _ method: String, key: String? = nil, query: [String: String] = [:],
        headers: [String: String] = [:], body: Data = Data(), date: Date = Date()
    ) throws -> URLRequest {
        try configuration.validate()
        guard var components = URLComponents(string: configuration.endpoint), let host = components.host else { throw S3Error.invalidConfiguration }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let object = key.map { configuration.objectPrefix + $0 }
        let pathParts = [basePath.isEmpty ? nil : basePath, Self.encode(configuration.bucket), object.map { Self.encode($0, preserveSlash: true) }]
        let path = "/" + pathParts.compactMap { $0 }.joined(separator: "/")
        components.percentEncodedPath = path
        let encodedQuery: [(String, String)] = query.map { (Self.encode($0.key), Self.encode($0.value)) }
        let sortedQuery = encodedQuery.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }
        let canonicalQuery = sortedQuery.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        guard let url = components.url else { throw S3Error.invalidConfiguration }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let payloadHash = Self.hash(body)
        let hostHeader = components.port.map { "\(host):\($0)" } ?? host
        var signedHeaders = headers
        signedHeaders["host"] = hostHeader
        signedHeaders["x-amz-date"] = timestamp
        signedHeaders["x-amz-content-sha256"] = payloadHash
        let names = signedHeaders.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signedHeaders[$0]!.trimmingCharacters(in: .whitespacesAndNewlines))\n" }.joined()
        let signedNames = names.joined(separator: ";")
        let canonical = [method, path, canonicalQuery, canonicalHeaders, signedNames, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(configuration.region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(Self.hash(Data(canonical.utf8)))"
        let dateKey = Self.hmac(Data(("AWS4" + secret).utf8), day)
        let regionKey = Self.hmac(dateKey, configuration.region)
        let serviceKey = Self.hmac(regionKey, "s3")
        let signingKey = Self.hmac(serviceKey, "aws4_request")
        let signature = Self.hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "PUT" { request.httpBody = body }
        for (name, value) in signedHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(scope), SignedHeaders=\(signedNames), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func request(
        _ method: String, key: String? = nil, query: [String: String] = [:],
        headers: [String: String] = [:], body: Data = Data()
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try signedRequest(method, key: key, query: query, headers: headers, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: S3NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw S3Error.requestFailed(response.statusCode, S3ListParser.errorCode(data))
        }
        return (data, response)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }

    private static func encode(_ text: String, preserveSlash: Bool = false) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + (preserveSlash ? "/" : ""))
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private final class S3NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class S3ListParser: NSObject, XMLParserDelegate {
    struct Page {
        var objects: [String: String] = [:]
        var truncated = false
        var nextToken: String?
    }

    private var page = Page()
    private var text = ""
    private var inContents = false
    private var key: String?
    private var etag: String?
    private var sawTruncated = false
    private var invalid = false
    private var code = ""
    private var objects: [(String, String)] = []
    private var encodingType: String?

    static func parse(_ data: Data) throws -> Page {
        let delegate = S3ListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawTruncated, !delegate.invalid else { throw S3Error.invalidResponse }
        var page = delegate.page
        // EncodingType is written after the object list, so the keys are
        // decoded once the whole page is read. A service that ignores
        // `encoding-type` returns raw keys, which must not be percent-decoded.
        for (raw, etag) in delegate.objects {
            let key = delegate.encodingType == "url" ? raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding : raw
            guard let key, page.objects.updateValue(etag, forKey: key) == nil else { throw S3Error.invalidResponse }
        }
        return page
    }

    static func errorCode(_ data: Data) -> String {
        let delegate = S3ListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.code
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        text = ""
        if elementName == "Contents" { inContents = true; key = nil; etag = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Key" where inContents: key = text
        case "ETag" where inContents: etag = text
        case "Contents":
            if let key, let etag, !etag.isEmpty { objects.append((key, etag)) } else { invalid = true }
            inContents = false
        case "EncodingType": encodingType = text
        case "IsTruncated":
            sawTruncated = true
            if text == "true" { page.truncated = true } else if text != "false" { invalid = true }
        case "NextContinuationToken": page.nextToken = text
        case "Code": code = text
        default: break
        }
    }
}
