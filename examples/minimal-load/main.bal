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
import ballerina/io;
import ballerinax/ai.aws.s3;
import ballerinax/aws.s3 as awsS3;

// Supplied via Config.toml — never hard-code credentials.
configurable string accessKeyId = ?;
configurable string secretAccessKey = ?;
configurable awsS3:Region region = awsS3:US_EAST_1;
configurable string bucket = ?;
configurable string prefix = "";

public function main() returns error? {
    s3:TextDataLoader loader = check new (
        {auth: {accessKeyId, secretAccessKey}, region},
        [
            {
                bucket,
                targets: [{path: prefix, recursive: true}]
            }
        ]
    );

    // `load()` returns a bare document when exactly one object is resolved, and an array
    // otherwise. Normalize to an array so the rest of the code has one shape to handle.
    ai:Document[]|ai:Document loaded = check loader.load();
    ai:Document[] documents = loaded is ai:Document[] ? loaded : [loaded];

    io:println(string `Loaded ${documents.length()} document(s) from '${bucket}'.`);
    io:println("");

    foreach ai:Document document in documents {
        ai:Metadata metadata = document.metadata ?: {};
        anydata key = metadata["key"];
        anydata eTag = metadata["eTag"];
        string content = document.content is string ? <string>document.content : "";

        io:println("key       : ", key is string ? key : "(unknown)");
        io:println("mimeType  : ", metadata.mimeType ?: "(none)");
        io:println("size      : ", metadata.fileSize ?: "(unknown)");
        io:println("eTag      : ", eTag is string ? eTag : "(none)");
        io:println("characters: ", content.length());
        // Show enough of the text to confirm extraction actually worked.
        io:println("preview   : ", content.length() > 200 ? content.substring(0, 200) + "..." : content);
        io:println("");
    }
}
