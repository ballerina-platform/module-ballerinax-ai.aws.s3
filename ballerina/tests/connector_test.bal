// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;
import ballerinax/aws.s3;

// Tests for the production seam over `ballerinax/aws.s3`. These deliberately make no network
// calls: `toS3Config` is a pure mapping that can be asserted field by field, and the pagination
// refusal short-circuits before any request is issued.

// ---------------------------------------------------------------------------
// The pagination refusal (short-circuits before any request)
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testListingRefusesPaginationWithClearMessage() returns error? {
    s3:Client s3Client = check buildS3Client(
        {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret", region: "us-east-1"});
    // Asking for anything past the first page must fail immediately, before a request is made:
    // `ballerinax/aws.s3` never surfaces a continuation token and emits `start-after` without a
    // separator, so a second page cannot be fetched correctly.
    S3Page|ai:Error result =
        listObjectPage(s3Client, "my-bucket", "docs/", "docs/last-key.txt", 1000);
    test:assertTrue(result is ai:Error, "Listing must refuse to paginate");
    if result is ai:Error {
        string message = result.message();
        test:assertTrue(message.includes("my-bucket"), "The error must name the bucket: " + message);
        test:assertTrue(message.includes("docs/"), "The error must name the prefix: " + message);
        test:assertTrue(message.includes("exceeds a single page"),
                "The error must explain the truncation: " + message);
        test:assertTrue(message.includes("Narrow the prefix"),
                "The error must say what to do about it: " + message);
    }
}

// ---------------------------------------------------------------------------
// ETag normalization
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testEtagQuotesAreStripped() {
    // S3 returns the ETag as an HTTP entity-tag, wrapped in literal double quotes. Callers
    // compare against the bare hex digest, so the quotes must not reach metadata.
    test:assertEquals(unquote("\"d41d8cd98f00b204e9800998ecf8427e\""),
            "d41d8cd98f00b204e9800998ecf8427e");
    test:assertEquals(unquote("d41d8cd98f00b204e9800998ecf8427e"),
            "d41d8cd98f00b204e9800998ecf8427e", "An unquoted ETag must pass through unchanged");
    test:assertEquals(unquote(""), "", "An absent ETag must stay empty");
    test:assertEquals(unquote("\""), "\"", "A lone quote must not be mangled");
}
