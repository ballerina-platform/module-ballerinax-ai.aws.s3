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

import ballerina/test;

// Tests for the production seam over `ballerinax/aws.s3`. These deliberately make no network
// calls. `listObjectPage` and `openObjectStream` both issue live requests through the connector
// (which now signs and paginates through the AWS SDK), so they are exercised by the integration
// suite rather than here; `unquote` is a pure normalization that can be asserted directly.

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
