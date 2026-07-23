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
import ballerinax/aws.s3;

# Builds the production `S3Api` implementation from a `ConnectionConfig`, mapping this
# package's auth union onto the underlying `ballerinax/aws.s3` client configuration.
isolated function buildS3Api(ConnectionConfig config) returns S3Api|ai:Error {
    s3:ConnectionConfig s3Config;
    Credentials auth = config.auth;
    if auth is StaticCredentials {
        // Static (or STS) credentials: pass the key pair and optional session token
        // through, selecting the connector's static-auth mode.
        s3Config = {
            accessKeyId: auth.accessKeyId,
            secretAccessKey: auth.secretAccessKey,
            region: config.region,
            authType: s3:AWS_STATIC_AUTH
        };
        string? sessionToken = auth?.sessionToken;
        if sessionToken is string {
            s3Config.sessionToken = sessionToken;
        }
    } else {
        // IAM-role mode: the connector fetches credentials from the EC2/ECS instance
        // metadata service, so no key pair is supplied.
        s3Config = {region: config.region, authType: s3:EC2_IAM_ROLE};
    }

    s3:Client|error s3Client = new (s3Config);
    if s3Client is error {
        return error ai:Error("Failed to initialize the AWS S3 client: " + s3Client.message(), s3Client);
    }
    return new ConnectorS3Api(s3Client);
}

# The production `S3Api`, backed by a `ballerinax/aws.s3` client.
#
# Two connector limitations are absorbed here so the rest of the loader can ignore them
# (see the package README's "Limitations"):
#  1. `s3:Client.listObjects` never surfaces `IsTruncated`/`NextContinuationToken`, and
#     its `start-after` query parameter is emitted without a separator so it corrupts the
#     signed request. There is therefore no working way to fetch a second listing page.
#     `listPage` serves the first page and, if asked for a later one (`startAfter != ()`),
#     fails with a clear message rather than issuing a broken request.
#  2. `s3:Client.getObject` returns a byte *stream*, not bytes; it is exposed as-is and
#     drained (with a size ceiling) by the caller.
isolated class ConnectorS3Api {
    *S3Api;

    private final s3:Client s3Client;

    isolated function init(s3:Client s3Client) {
        self.s3Client = s3Client;
    }

    public isolated function listPage(string bucket, string? prefix, string? startAfter, int maxKeys)
            returns S3Page|ai:Error {
        if startAfter is string {
            // A second page was requested, which this connector cannot fetch (see the
            // class doc). Report it as a clear truncation error naming what to do.
            return error ai:Error(string `Listing for bucket '${bucket}'` +
                (prefix is string ? string ` prefix '${prefix}'` : "") +
                string ` exceeds a single page and cannot be fully read: ballerinax/aws.s3 ` +
                string `does not surface continuation tokens and its 'start-after' paging is ` +
                string `broken. Narrow the prefix or lower 'maxDocuments' so the result fits ` +
                string `one page (up to ${maxKeys} objects).`);
        }
        s3:S3Object[]|error listing = self.s3Client->listObjects(bucket, maxKeys = maxKeys, prefix = prefix);
        if listing is error {
            return error ai:Error(
                string `Failed to list objects in bucket '${bucket}'` +
                (prefix is string ? string ` under prefix '${prefix}'` : "") +
                string `: ${listing.message()}`, listing);
        }
        S3Item[] items = [];
        foreach s3:S3Object obj in listing {
            string? key = obj?.objectName;
            if key is () || key == "" {
                continue;
            }
            items.push({
                key,
                size: obj?.objectSize ?: "",
                eTag: obj?.eTag ?: "",
                lastModified: obj?.lastModified ?: ""
            });
        }
        // The connector cannot tell us whether the listing was truncated, so a full page
        // (exactly `maxKeys` objects) is treated as "possibly truncated". The caller then
        // attempts the next page, which surfaces the clear error above.
        return {items, truncated: items.length() == maxKeys};
    }

    public isolated function getObjectStream(string bucket, string key)
            returns stream<byte[], io:Error?>|ai:Error {
        stream<byte[], io:Error?>|error objStream = self.s3Client->getObject(bucket, key);
        if objStream is error {
            return error ai:Error(
                string `Failed to open object '${key}' in bucket '${bucket}': ${objStream.message()}`, objStream);
        }
        return objStream;
    }
}
