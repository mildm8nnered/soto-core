//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2020 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import SotoCore
import SotoTestUtils
import XCTest

class AWSServiceTests: XCTestCase {
    struct TestService: AWSService {
        var client: AWSClient
        var config: AWSServiceConfig

        /// init
        init(client: AWSClient, config: AWSServiceConfig) {
            self.client = client
            self.config = config
        }

        /// patch init
        init(from: Self, patch: AWSServiceConfig.Patch) {
            self.client = from.client
            self.config = from.config.with(patch: patch)
        }
    }

    func testRegion() {
        let client = createAWSClient(credentialProvider: .empty)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let serviceConfig = createServiceConfig(region: .apnortheast2)
        let service = TestService(client: client, config: serviceConfig)
        XCTAssertEqual(service.region, .apnortheast2)
    }

    func testEndpoint() {
        let client = createAWSClient(credentialProvider: .empty)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let serviceConfig = createServiceConfig(endpoint: "https://my-endpoint.com")
        let service = TestService(client: client, config: serviceConfig)
        XCTAssertEqual(service.endpoint, "https://my-endpoint.com")
    }

    func testWith() {
        let client = createAWSClient(credentialProvider: .empty)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let serviceConfig = createServiceConfig()
        let service = TestService(client: client, config: serviceConfig)
        let service2 = service.with(timeout: .seconds(2048), options: .init(rawValue: 0x67FF))
        XCTAssertEqual(service2.config.timeout, .seconds(2048))
        XCTAssertEqual(service2.config.options, .init(rawValue: 0x67FF))
    }

    func testWithMiddleware() {
        struct TestMiddleware: AWSServiceMiddleware {}
        let client = createAWSClient(credentialProvider: .empty)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let serviceConfig = createServiceConfig()
        let service = TestService(client: client, config: serviceConfig)
        let service2 = service.with(middlewares: [TestMiddleware()])
        XCTAssertNotNil(service2.config.middlewares.first { type(of: $0) == TestMiddleware.self })
    }

    func testWithRegion() {
        let client = createAWSClient(credentialProvider: .empty)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let service = TestService(client: client, config: createServiceConfig(region: .apnortheast2))
        let service2 = TestService(client: client, config: createServiceConfig(region: .useast1)).with(region: .apnortheast2)
        XCTAssertEqual(service.region, service2.region)
        XCTAssertEqual(service.endpoint, service2.endpoint)
    }
}
