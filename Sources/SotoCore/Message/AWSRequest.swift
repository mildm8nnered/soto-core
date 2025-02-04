//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2021 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.CharacterSet
import struct Foundation.Data
import struct Foundation.Date
import struct Foundation.URL
import struct Foundation.URLComponents
import NIOCore
import NIOHTTP1
import SotoCrypto
import SotoSignerV4

/// Object encapsulating all the information needed to generate a raw HTTP request to AWS
public struct AWSRequest {
    /// request AWS region
    public let region: Region
    /// request URL
    public var url: URL
    /// request communication protocol
    public let serviceProtocol: ServiceProtocol
    /// AWS operation name
    public let operation: String
    /// request HTTP method
    public let httpMethod: HTTPMethod
    /// request headers
    public var httpHeaders: HTTPHeaders
    /// request body
    public var body: Body

    /// Create HTTP Client request from AWSRequest.
    /// If the signer's credentials are available the request will be signed. Otherwise defaults to an unsigned request
    func createHTTPRequest(signer: AWSSigner, serviceConfig: AWSServiceConfig) -> AWSHTTPRequest {
        // if credentials are empty don't sign request
        if signer.credentials.isEmpty() {
            return self.toHTTPRequest(byteBufferAllocator: serviceConfig.byteBufferAllocator)
        }

        return self.toHTTPRequestWithSignedHeader(signer: signer, serviceConfig: serviceConfig)
    }

    /// Create HTTP Client request from AWSRequest
    func toHTTPRequest(byteBufferAllocator: ByteBufferAllocator) -> AWSHTTPRequest {
        return AWSHTTPRequest(url: url, method: httpMethod, headers: httpHeaders, body: body.asPayload(byteBufferAllocator: byteBufferAllocator))
    }

    /// Create HTTP Client request with signed headers from AWSRequest
    func toHTTPRequestWithSignedHeader(signer: AWSSigner, serviceConfig: AWSServiceConfig) -> AWSHTTPRequest {
        let payload = self.body.asPayload(byteBufferAllocator: serviceConfig.byteBufferAllocator)
        let bodyDataForSigning: AWSSigner.BodyData?
        switch payload.payload {
        case .byteBuffer(let buffer):
            bodyDataForSigning = .byteBuffer(buffer)
        case .stream(let reader):
            if signer.name == "s3", !serviceConfig.options.contains(.s3DisableChunkedUploads) {
                assert(reader.size != nil, "S3 stream requires size")
                var headers = httpHeaders
                // need to add this header here as it needs to be included in the signed headers
                headers.add(name: "x-amz-decoded-content-length", value: reader.size!.description)
                let (signedHeaders, seedSigningData) = signer.startSigningChunks(url: url, method: httpMethod, headers: headers, date: Date())
                let s3Reader = S3ChunkedStreamReader(
                    size: reader.size!,
                    seedSigningData: seedSigningData,
                    signer: signer,
                    byteBufferAllocator: serviceConfig.byteBufferAllocator,
                    read: reader.read
                )
                let payload = AWSPayload.streamReader(s3Reader)
                return AWSHTTPRequest(url: url, method: httpMethod, headers: signedHeaders, body: payload)
            } else {
                bodyDataForSigning = .unsignedPayload
            }
        case .empty:
            bodyDataForSigning = nil
        }
        let signedHeaders = signer.signHeaders(url: url, method: httpMethod, headers: httpHeaders, body: bodyDataForSigning, date: Date())
        return AWSHTTPRequest(url: url, method: httpMethod, headers: signedHeaders, body: payload)
    }

    // return new request with middleware applied
    func applyMiddlewares(_ middlewares: [AWSServiceMiddleware], config: AWSServiceConfig) throws -> AWSRequest {
        var awsRequest = self
        // apply middleware to request
        let context = AWSMiddlewareContext(options: config.options)
        for middleware in middlewares {
            awsRequest = try middleware.chain(request: awsRequest, context: context)
        }
        return awsRequest
    }
}

extension AWSRequest {
    internal init(operation operationName: String, path: String, httpMethod: HTTPMethod, configuration: AWSServiceConfig) throws {
        var headers = HTTPHeaders()

        guard let url = URL(string: "\(configuration.endpoint)\(path)"), let _ = url.host else {
            throw AWSClient.ClientError.invalidURL
        }

        // set x-amz-target header
        if let target = configuration.amzTarget {
            headers.replaceOrAdd(name: "x-amz-target", value: "\(target).\(operationName)")
        }

        self.region = configuration.region
        self.url = url
        self.serviceProtocol = configuration.serviceProtocol
        self.operation = operationName
        self.httpMethod = httpMethod
        self.httpHeaders = headers
        // Query and EC2 protocols require the Action and API Version in the body
        switch configuration.serviceProtocol {
        case .query, .ec2:
            let params = ["Action": operationName, "Version": configuration.apiVersion]
            self.body = try .text(QueryEncoder().encode(params)!)
        default:
            self.body = .empty
        }

        addStandardHeaders()
    }

    internal init<Input: AWSEncodableShape>(
        operation operationName: String,
        path: String,
        httpMethod: HTTPMethod,
        input: Input,
        hostPrefix: String? = nil,
        configuration: AWSServiceConfig
    ) throws {
        var headers = HTTPHeaders()
        var path = path
        var hostPrefix = hostPrefix
        var body: Body = .empty
        var queryParams: [(key: String, value: Any)] = []

        // validate input parameters
        try input.validate()

        // set x-amz-target header
        if let target = configuration.amzTarget {
            headers.replaceOrAdd(name: "x-amz-target", value: "\(target).\(operationName)")
        }

        // TODO: should replace with Encodable
        let mirror = Mirror(reflecting: input)
        var memberVariablesCount = mirror.children.count - Input._encoding.count

        // extract header, query and uri params
        for encoding in Input._encoding {
            if let value = mirror.getAttribute(forKey: encoding.label) {
                switch encoding.location {
                case .header(let location):
                    switch value {
                    case let string as AWSRequestEncodableString:
                        string.encoded.map { headers.replaceOrAdd(name: location, value: $0) }
                    default:
                        headers.replaceOrAdd(name: location, value: "\(value)")
                    }

                case .headerPrefix(let prefix):
                    if let dictionary = value as? AWSRequestEncodableDictionary {
                        dictionary.encoded.forEach { headers.replaceOrAdd(name: "\(prefix)\($0.key)", value: $0.value) }
                    }

                case .querystring(let location):
                    switch value {
                    case let string as AWSRequestEncodableString:
                        string.encoded.map { queryParams.append((key: location, value: $0)) }
                    case let array as AWSRequestEncodableArray:
                        array.encoded.forEach { queryParams.append((key: location, value: $0)) }
                    case let dictionary as AWSRequestEncodableDictionary:
                        dictionary.encoded.forEach { queryParams.append($0) }
                    default:
                        queryParams.append((key: location, value: "\(value)"))
                    }

                case .uri(let location):
                    path = path
                        .replacingOccurrences(of: "{\(location)}", with: Self.urlEncodePathComponent(String(describing: value)))
                        .replacingOccurrences(of: "{\(location)+}", with: Self.urlEncodePath(String(describing: value)))

                case .hostname(let location):
                    hostPrefix = hostPrefix?
                        .replacingOccurrences(of: "{\(location)}", with: Self.urlEncodePathComponent(String(describing: value)))

                default:
                    memberVariablesCount += 1
                }
            }
        }

        switch configuration.serviceProtocol {
        case .json, .restjson:
            if let shapeWithPayload = Input.self as? AWSShapeWithPayload.Type {
                let payload = shapeWithPayload._payloadPath
                if let payloadBody = mirror.getAttribute(forKey: payload) {
                    switch payloadBody {
                    case let awsPayload as AWSPayload:
                        Self.verifyStream(operation: operationName, payload: awsPayload, input: shapeWithPayload)
                        body = .raw(awsPayload)
                    case let shape as AWSEncodableShape:
                        body = .json(try shape.encodeAsJSON(byteBufferAllocator: configuration.byteBufferAllocator))
                    default:
                        preconditionFailure("Cannot add this as a payload")
                    }
                } else {
                    body = .empty
                }
            } else {
                // only include the body if there are members that are output in the body.
                if memberVariablesCount > 0 {
                    body = .json(try input.encodeAsJSON(byteBufferAllocator: configuration.byteBufferAllocator))
                } else if httpMethod == .PUT || httpMethod == .POST {
                    // PUT and POST requests require a body even if it is empty. This is not the case with XML
                    body = .json(configuration.byteBufferAllocator.buffer(string: "{}"))
                }
            }

        case .restxml:
            if let shapeWithPayload = Input.self as? AWSShapeWithPayload.Type {
                let payload = shapeWithPayload._payloadPath
                if let payloadBody = mirror.getAttribute(forKey: payload) {
                    switch payloadBody {
                    case let awsPayload as AWSPayload:
                        Self.verifyStream(operation: operationName, payload: awsPayload, input: shapeWithPayload)
                        body = .raw(awsPayload)
                    case let shape as AWSEncodableShape:
                        var rootName: String?
                        // extract custom payload name
                        if let encoding = Input.getEncoding(for: payload), case .body(let locationName) = encoding.location {
                            rootName = locationName
                        }
                        body = .xml(try shape.encodeAsXML(rootName: rootName, namespace: configuration.xmlNamespace))
                    default:
                        preconditionFailure("Cannot add this as a payload")
                    }
                } else {
                    body = .empty
                }
            } else {
                // only include the body if there are members that are output in the body.
                if memberVariablesCount > 0 {
                    body = .xml(try input.encodeAsXML(namespace: configuration.xmlNamespace))
                }
            }

        case .query:
            if let query = try input.encodeAsQuery(with: ["Action": operationName, "Version": configuration.apiVersion]) {
                body = .text(query)
            }

        case .ec2:
            if let query = try input.encodeAsQueryForEC2(with: ["Action": operationName, "Version": configuration.apiVersion]) {
                body = .text(query)
            }
        }

        guard var urlComponents = URLComponents(string: "\(configuration.endpoint)\(path)") else {
            throw AWSClient.ClientError.invalidURL
        }

        if let hostPrefix = hostPrefix, let host = urlComponents.host {
            urlComponents.host = hostPrefix + host
        }

        // add queries from the parsed path to the query params list
        if let pathQueryItems = urlComponents.queryItems {
            for item in pathQueryItems {
                queryParams.append((key: item.name, value: item.value ?? ""))
            }
        }

        // Set query params. Percent encode these ourselves as Foundation and AWS disagree on what should be percent encoded in the query values
        // Also the signer doesn't percent encode the queries so they need to be encoded here
        if queryParams.count > 0 {
            let urlQueryString = queryParams
                .map { (key: $0.key, value: "\($0.value)") }
                .sorted {
                    // sort by key. if key are equal then sort by value
                    if $0.key < $1.key { return true }
                    if $0.key > $1.key { return false }
                    return $0.value < $1.value
                }
                .map { "\($0.key)=\(Self.urlEncodeQueryParam($0.value))" }
                .joined(separator: "&")
            urlComponents.percentEncodedQuery = urlQueryString
        }

        guard let url = urlComponents.url else {
            throw AWSClient.ClientError.invalidURL
        }

        headers = Self.calculateChecksumHeader(
            headers: headers,
            body: body,
            shapeType: Input.self,
            configuration: configuration
        )

        self.region = configuration.region
        self.url = url
        self.serviceProtocol = configuration.serviceProtocol
        self.operation = operationName
        self.httpMethod = httpMethod
        self.httpHeaders = headers
        self.body = body

        addStandardHeaders()
    }

    /// Calculate checksum header for request
    /// - Parameters:
    ///   - headers: request headers
    ///   - body: request body
    ///   - shapeType: Request shape type
    ///   - configuration: Service configuration
    /// - Returns: New set of headers
    private static func calculateChecksumHeader<Input: AWSEncodableShape>(
        headers: HTTPHeaders,
        body: Body,
        shapeType: Input.Type,
        configuration: AWSServiceConfig
    ) -> HTTPHeaders {
        var headers = headers
        var checksumType: ChecksumType?
        if shapeType._options.contains(.checksumHeader) {
            checksumType = headers["x-amz-sdk-checksum-algorithm"].first.map { ChecksumType(rawValue: $0) } ?? nil
        }
        if checksumType == nil {
            if Input._options.contains(.checksumRequired) ||
                (Input._options.contains(.md5ChecksumHeader) && configuration.options.contains(.calculateMD5))
            {
                checksumType = .md5
            }
        }

        guard let checksumType = checksumType,
              let buffer = body.asByteBuffer(byteBufferAllocator: configuration.byteBufferAllocator),
              let checksumHeader = Self.checksumHeaders[checksumType],
              headers[checksumHeader].first == nil else { return headers }

        var checksum: String?
        switch checksumType {
        case .crc32:
            let bufferView = ByteBufferView(buffer)
            let crc = soto_crc32(0, bytes: bufferView)
            var crc32 = UInt32(crc).bigEndian
            let data = withUnsafePointer(to: &crc32) { pointer in
                return Data(bytes: pointer, count: 4)
            }
            checksum = data.base64EncodedString()
        case .crc32c:
            let bufferView = ByteBufferView(buffer)
            let crc = soto_crc32c(0, bytes: bufferView)
            var crc32 = UInt32(crc).bigEndian
            let data = withUnsafePointer(to: &crc32) { pointer in
                return Data(bytes: pointer, count: 4)
            }
            checksum = data.base64EncodedString()
        case .sha1:
            checksum = calculateChecksum(buffer, function: Insecure.SHA1.self)
        case .sha256:
            checksum = calculateChecksum(buffer, function: SHA256.self)
        case .md5:
            checksum = calculateChecksum(buffer, function: Insecure.MD5.self)
        }
        if let checksum = checksum {
            headers.add(name: checksumHeader, value: checksum)
        }
        return headers
    }

    /// Add headers standard to all requests "content-type" and "user-agent"
    private mutating func addStandardHeaders() {
        httpHeaders.replaceOrAdd(name: "user-agent", value: "Soto/6.0")
        guard httpHeaders["content-type"].first == nil else {
            return
        }
        guard httpMethod != .GET, httpMethod != .HEAD else {
            return
        }

        if case .empty = body {
            // don't add a content-type header when there is no content
        } else if case .restjson = serviceProtocol, case .raw = body {
            httpHeaders.replaceOrAdd(name: "content-type", value: "binary/octet-stream")
        } else {
            httpHeaders.replaceOrAdd(name: "content-type", value: serviceProtocol.contentType)
        }
    }

    /// this list of query allowed characters comes from https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    static let queryAllowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let pathAllowedCharacters = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "+"))
    static let pathComponentAllowedCharacters = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "+/"))

    /// percent encode query parameter value.
    private static func urlEncodeQueryParam(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: AWSRequest.queryAllowedCharacters) ?? value
    }

    /// percent encode path value.
    private static func urlEncodePath(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: AWSRequest.pathAllowedCharacters) ?? value
    }

    /// percent encode path component value. ie also encode "/"
    private static func urlEncodePathComponent(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: AWSRequest.pathComponentAllowedCharacters) ?? value
    }

    /// verify  streaming is allowed for this operation
    internal static func verifyStream(operation: String, payload: AWSPayload, input: AWSShapeWithPayload.Type) {
        guard case .stream(let reader) = payload.payload else { return }
        precondition(input._options.contains(.allowStreaming), "\(operation) does not allow streaming of data")
        precondition(reader.size != nil || input._options.contains(.allowChunkedStreaming), "\(operation) does not allow chunked streaming of data. Please supply a data size.")
    }

    private static func calculateChecksum<H: HashFunction>(_ byteBuffer: ByteBuffer, function: H.Type) -> String? {
        // if request has a body, calculate the MD5 for that body
        let byteBufferView = byteBuffer.readableBytesView
        return byteBufferView.withContiguousStorageIfAvailable { bytes in
            return Data(H.hash(data: bytes)).base64EncodedString()
        }
    }

    private enum ChecksumType: String {
        case crc32 = "CRC32"
        case crc32c = "CRC32C"
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case md5 = "MD5"
    }

    private static let checksumHeaders: [ChecksumType: String] = [
        .crc32: "x-amz-checksum-crc32",
        .crc32c: "x-amz-checksum-crc32c",
        .sha1: "x-amz-checksum-sha1",
        .sha256: "x-amz-checksum-sha256",
        .md5: "content-md5",
    ]
}

private protocol AWSRequestEncodableArray {
    var encoded: [String] { get }
}

extension Array: AWSRequestEncodableArray {
    var encoded: [String] { return self.map { "\($0)" }}
}

private protocol AWSRequestEncodableDictionary {
    var encoded: [(key: String, value: String)] { get }
}

extension Dictionary: AWSRequestEncodableDictionary {
    var encoded: [(key: String, value: String)] {
        return self.map { (key: "\($0.key)", value: "\($0.value)") }
    }
}

private protocol AWSRequestEncodableString {
    var encoded: String? { get }
}

extension CustomCoding: AWSRequestEncodableString where Coder: CustomEncoder {
    var encoded: String? {
        return Coder.string(from: self.wrappedValue)
    }
}

extension OptionalCustomCoding: AWSRequestEncodableString where Coder: CustomEncoder {
    var encoded: String? {
        guard let value = self.wrappedValue else { return nil }
        return Coder.string(from: value)
    }
}
