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
import ballerinax/aws.s3;

// Everything that touches `ballerinax/aws.s3` lives here, so the loader deals in normalized
// values and the connector's quirks are absorbed in one place.

// A normalized S3 listing entry — the subset of an object's metadata the loader uses. The
// connector's `s3:S3Object` fields are normalized once here (the size is carried as a decimal
// string so the loader's metadata mapping stays uniform) rather than being handled throughout
// the loader. They are parsed leniently when document metadata is built: an absent or
// unparseable value is omitted from `ai:Metadata` rather than defaulted, so a malformed
// timestamp or size never fails a load.
type S3Item record {|
    // The full object key, including any '/' separators.
    string key;
    // The object size in bytes as reported by S3, as a decimal string; "" if absent.
    string size = "";
    // The object's entity tag, with S3's surrounding double quotes stripped; "" if absent.
    string eTag = "";
    // The last-modified timestamp as reported by S3 (ISO-8601); "" if absent.
    string lastModified = "";
|};

// One page of an S3 object listing.
type S3Page record {|
    // The objects on this page, in ascending key order.
    S3Item[] items;
    // Whether more objects exist beyond this page.
    boolean truncated;
|};

// Builds the S3 client the loader reads through, from the connector's own configuration.
isolated function buildS3Client(s3:ConnectionConfig config) returns s3:Client|ai:Error {
    s3:Client|error s3Client = new s3:Client(config);
    if s3Client is error {
        return error ai:Error("Failed to initialize the AWS S3 client: " + s3Client.message(), s3Client);
    }
    return s3Client;
}

// Lists one page of objects under a prefix, normalizing the connector's result.
//
// `startAfter` is the key-marker for the next page: `()` requests the first page, and a key
// requests the objects lexicographically after it. `ballerinax/aws.s3` 5.0.0 signs and paginates
// through the AWS SDK, so `startAfter` and the returned `isTruncated` flag are both honoured —
// the caller (`loadPrefix`) walks every page. `s3:S3Object` fields are normalized here (size to a
// decimal string, ETag with S3's surrounding double quotes stripped) rather than in the loader.
isolated function listObjectPage(s3:Client s3Client, string bucket, string? prefix, string? startAfter,
        int maxKeys) returns S3Page|ai:Error {
    // `prefix` and `startAfter` are optional `s3:ListObjectsConfig` fields typed `string`, so an
    // absent value is omitted (never passed as `()`) by selecting the matching call arm.
    s3:ListObjectsResponse|s3:Error listing;
    if prefix is string && startAfter is string {
        listing = s3Client->listObjects(bucket, prefix = prefix, startAfter = startAfter, maxKeys = maxKeys);
    } else if prefix is string {
        listing = s3Client->listObjects(bucket, prefix = prefix, maxKeys = maxKeys);
    } else if startAfter is string {
        listing = s3Client->listObjects(bucket, startAfter = startAfter, maxKeys = maxKeys);
    } else {
        listing = s3Client->listObjects(bucket, maxKeys = maxKeys);
    }
    if listing is s3:Error {
        return error ai:Error(
            string `Failed to list objects in bucket '${bucket}'` +
            (prefix is string ? string ` under prefix '${prefix}'` : "") +
            string `: ${listing.message()}`, listing);
    }
    S3Item[] items = [];
    foreach s3:S3Object obj in listing.objects {
        string key = obj.key;
        if key == "" {
            continue;
        }
        items.push({
            key,
            size: obj.size.toString(),
            // S3 returns the ETag wrapped in literal double quotes (it is an HTTP entity-tag).
            // Strip them so the metadata value compares against the bare hex digest callers have.
            eTag: unquote(obj.eTag),
            lastModified: obj.lastModified
        });
    }
    return {items, truncated: listing.isTruncated};
}

// Opens a byte stream over an object's content. The caller drains and closes the stream.
isolated function openObjectStream(s3:Client s3Client, string bucket, string key)
        returns stream<byte[], error?>|ai:Error {
    stream<byte[], error?>|error objStream = s3Client->getObjectAsStream(bucket, key);
    if objStream is error {
        return error ai:Error(
            string `Failed to open object '${key}' in bucket '${bucket}': ${objStream.message()}`, objStream);
    }
    return objStream;
}

// Strips a single pair of surrounding double quotes, as S3 wraps ETag values in them.
isolated function unquote(string value) returns string {
    if value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"") {
        return value.substring(1, value.length() - 1);
    }
    return value;
}
