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

// Everything that touches `ballerinax/aws.s3` lives here, so the loader deals in normalized
// values and the connector's quirks are absorbed in one place.

// A normalized S3 listing entry — the subset of an object's metadata the loader uses. The
// connector reports every `s3:S3Object` field as an optional string, so these are normalized
// once here rather than being null-checked throughout the loader. They are parsed leniently
// when document metadata is built: an absent or unparseable value is omitted from `ai:Metadata`
// rather than defaulted, so a malformed timestamp or size never fails a load.
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
// Two connector limitations are absorbed here (see the package README's "Limitations"):
//  1. `listObjects` never surfaces `IsTruncated`/`NextContinuationToken`, and its `start-after`
//     query parameter is emitted without a separator so it corrupts the signed request. There is
//     therefore no working way to fetch a second listing page: this serves the first page and,
//     if asked for a later one (`startAfter != ()`), fails with a clear message rather than
//     issuing a broken request.
//  2. Every `s3:S3Object` field is an optional string, so keys are validated and sizes,
//     timestamps and ETags are normalized here rather than in the loader.
isolated function listObjectPage(s3:Client s3Client, string bucket, string? prefix, string? startAfter,
        int maxKeys) returns S3Page|ai:Error {
    if startAfter is string {
        return error ai:Error(string `Listing for bucket '${bucket}'` +
            (prefix is string ? string ` prefix '${prefix}'` : "") +
            string ` exceeds a single page and cannot be fully read: ballerinax/aws.s3 ` +
            string `does not surface continuation tokens and its 'start-after' paging is ` +
            string `broken. Narrow the prefix or lower 'maxDocuments' so the result fits ` +
            string `one page (up to ${maxKeys} objects).`);
    }
    s3:S3Object[]|error listing = s3Client->listObjects(bucket, maxKeys = maxKeys, prefix = prefix);
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
            // S3 returns the ETag wrapped in literal double quotes (it is an HTTP entity-tag).
            // Strip them so the metadata value compares against the bare hex digest callers have.
            eTag: unquote(obj?.eTag ?: ""),
            lastModified: obj?.lastModified ?: ""
        });
    }
    // The connector cannot tell us whether the listing was truncated, so a full page is treated
    // as "possibly truncated". Deliberately measured against the raw listing length rather than
    // `items`: an entry skipped above for having no key would otherwise make a full page look
    // short, and the caller would stop early and silently return a partial result.
    return {items, truncated: listing.length() >= maxKeys};
}

// Opens a byte stream over an object's content. The caller drains and closes the stream.
isolated function openObjectStream(s3:Client s3Client, string bucket, string key)
        returns stream<byte[], io:Error?>|ai:Error {
    stream<byte[], io:Error?>|error objStream = s3Client->getObject(bucket, key);
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
