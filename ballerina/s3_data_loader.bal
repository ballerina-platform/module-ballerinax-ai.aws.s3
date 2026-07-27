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
import ballerina/log;
import ballerinax/aws.s3;

// S3's ListObjectsV2 caps a single page at 1000 keys; the loader always requests the
// maximum so a full page is a reliable "possibly truncated" signal.
const int MAX_KEYS_PER_PAGE = 1000;

# A data loader that reads objects from AWS S3 buckets as text for a RAG ingestion
# pipeline. It implements `ai:DataLoader`, so what it loads feeds directly into
# `ai:KnowledgeBase.ingest`.
#
# Natively-textual objects (`md`, `html`, `htm`, `txt`, `csv`, `json`, `xml`, `yaml`, …)
# are decoded directly; `pdf`, `docx`, and `pptx` are extracted in memory via Apache Tika.
# Legacy binary Office formats (`doc`, `ppt`, `xls`, `xlsx`) are not supported.
@display {
    label: "AWS S3 Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final s3:Client s3Client;
    private final readonly & Source[] sources;
    private final int maxObjectSize;

    # Initializes the AWS S3 data loader.
    #
    # + s3 - Either an `s3:ConnectionConfig` describing how to reach S3 (the loader builds the
    #        client from it), or an already-configured `s3:Client` to reuse
    # + sources - One or more buckets, each with the targets (prefixes/keys) to load
    # + options - Loader-wide options: the document cap and the in-memory size ceiling
    # + return - An `ai:Error` if the configuration is invalid or the client cannot be built
    public isolated function init(@display {label: "Connection Config"} s3:ConnectionConfig|s3:Client s3,
            @display {label: "Data Sources"} Source[] sources,
            @display {label: "Loader Options"} LoaderOptions options = {}) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the AWS S3 data loader");
        }
        if options.maxObjectSize < 1 {
            return error ai:Error("maxObjectSize must be at least 1");
        }
        self.s3Client = s3 is s3:Client ? s3 : check buildS3Client(s3);
        self.sources = sources.cloneReadOnly();
        self.maxObjectSize = options.maxObjectSize;
    }

    # Loads the configured S3 objects as text documents.
    #
    # + return - The single loaded document when exactly one object is resolved, an array of
    #            documents otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            foreach Target target in src.targets {
                ai:Document[] loaded = check self.loadTarget(src.bucket, target);
                documents.push(...loaded);
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // Loads a single target, choosing prefix traversal or exact-key resolution. A value
    // ending in `/` (or empty) is a prefix; anything else is tried as an exact key first and
    // falls back to a prefix on a miss.
    private isolated function loadTarget(string bucket, Target target)
            returns ai:Document[]|ai:Error {
        string path = target.path;
        if path == "" || path.endsWith("/") {
            return self.loadPrefix(bucket, path, target.recursive, target.includeExtensions);
        }
        S3Item? exact = check self.findExactKey(bucket, path);
        if exact is S3Item {
            return [check self.loadExactKey(bucket, exact)];
        }
        // Exact-key miss: treat the value as a prefix instead.
        return self.loadPrefix(bucket, path, target.recursive, target.includeExtensions);
    }

    // Resolves an exact key by listing under it and looking for an identical key. Listing
    // (rather than a HEAD/GET probe) avoids downloading an object merely to test existence.
    private isolated function findExactKey(string bucket, string key) returns S3Item?|ai:Error {
        S3Page page = check listObjectPage(self.s3Client, bucket, key, (), MAX_KEYS_PER_PAGE);
        foreach S3Item item in page.items {
            if item.key == key {
                return item;
            }
        }
        return ();
    }

    // Loads an explicitly named key. Unlike a prefix walk, an unsupported named key is an
    // error (the caller asked for it by name), not a silent skip.
    private isolated function loadExactKey(string bucket, S3Item item) returns ai:TextDocument|ai:Error {
        match classify(item.key, ()) {
            UNSUPPORTED_OFFICE => {
                return error ai:Error(string `Unsupported file type for key '${item.key}' in bucket ` +
                    string `'${bucket}': text extraction for the Microsoft Office formats ` +
                    string `(.doc, .ppt, .xls, .xlsx) is not supported. Convert the document to ` +
                    string `.docx, .pptx or PDF.`);
            }
            UNSUPPORTED => {
                return error ai:Error(
                    string `Unsupported (non-text) file type for key '${item.key}' in bucket '${bucket}'`);
            }
        }
        ai:TextDocument? document = check self.loadObject(bucket, item);
        if document is () {
            // Unreachable: the type was classified as supported above.
            return error ai:Error(
                string `Failed to build a document for key '${item.key}' in bucket '${bucket}'`);
        }
        return document;
    }

    // Lists a prefix and loads all its supported objects, paginating with key-marker paging.
    // The loop advances by the last key seen and stops on the last page, a zero-item page, or a
    // repeated marker — so it reads the whole prefix and can never spin forever. Like the
    // SharePoint loader, there is no document cap: every matching object is returned.
    private isolated function loadPrefix(string bucket, string prefix, boolean recursive,
            string[]? includeExtensions) returns ai:Document[]|ai:Error {
        ai:Document[] documents = [];
        string? marker = ();
        string? effectivePrefix = prefix == "" ? () : prefix;
        while true {
            S3Page page = check listObjectPage(self.s3Client, bucket, effectivePrefix, marker, MAX_KEYS_PER_PAGE);
            foreach S3Item item in page.items {
                if !includeInPrefixWalk(item, prefix, recursive, includeExtensions) {
                    continue;
                }
                ai:TextDocument? document = check self.loadObjectSkippingUnsupported(bucket, item);
                if document is ai:TextDocument {
                    documents.push(document);
                }
            }
            if !page.truncated {
                break; // last page
            }
            if page.items.length() == 0 {
                break; // GUARD: a truncated but empty page cannot advance the marker
            }
            string nextMarker = page.items[page.items.length() - 1].key;
            if nextMarker == marker {
                // GUARD: a truncated page whose last key equals the current marker cannot
                // advance paging, so bail rather than loop forever. Not expected in practice.
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix == "" ? "" : string ` under prefix '${prefix}'`) +
                    string ` is truncated and cannot be fully read. Narrow the prefix.`);
            }
            marker = nextMarker;
        }
        return documents;
    }

    // Decides whether to load an object found while walking a prefix, applying the folder,
    // recursion, and extension rules (unsupported-type filtering happens at load time).
    private isolated function loadObjectSkippingUnsupported(string bucket, S3Item item)
            returns ai:TextDocument?|ai:Error {
        match classify(item.key, ()) {
            UNSUPPORTED_OFFICE => {
                log:printWarn("Skipping an unsupported Microsoft Office object: text extraction " +
                        "for .doc/.ppt/.xls/.xlsx is not supported", bucket = bucket, key = item.key);
                return ();
            }
            UNSUPPORTED => {
                log:printWarn("Skipping a non-text object", bucket = bucket, key = item.key);
                return ();
            }
        }
        return self.loadObject(bucket, item);
    }

    // Downloads an object's content (draining the stream with the size ceiling) and builds a
    // text document from it.
    private isolated function loadObject(string bucket, S3Item item) returns ai:TextDocument?|ai:Error {
        // The listing already reported the size, so an over-sized object can be rejected before
        // a byte is transferred — saving the download time and egress cost of a request that
        // `drainStream` would abort anyway. The drain still enforces the ceiling, because the
        // reported size is not guaranteed to be present or accurate.
        int|error reportedSize = int:fromString(item.size);
        if reportedSize is int && reportedSize > self.maxObjectSize {
            return error ai:Error(string `Object '${item.key}' in bucket '${bucket}' is ` +
                string `${reportedSize} bytes, which exceeds the configured maximum size of ` +
                string `${self.maxObjectSize} bytes, and was not read into memory.`);
        }
        stream<byte[], error?> objStream = check openObjectStream(self.s3Client, bucket, item.key);
        byte[] content = check drainStream(objStream, self.maxObjectSize, bucket, item.key);
        return buildDocument(content, bucket, item.key, item.size, item.lastModified, item.eTag);
    }
}

# Decides whether an object found while walking a prefix should be considered for loading,
# applying (in order): the console-placeholder skip, the non-recursive same-level filter, and
# the extension allowlist. Unsupported file types are filtered later, at load time.
#
# + item - The listing entry under consideration
# + prefix - The prefix being walked (possibly empty)
# + recursive - Whether nested keys are included
# + includeExtensions - The extension allowlist (`()`/empty = all)
# + return - `true` if the object should be loaded, `false` to skip it
isolated function includeInPrefixWalk(S3Item item, string prefix, boolean recursive,
        string[]? includeExtensions) returns boolean {
    string key = item.key;
    // Skip S3 console "folder" placeholders: zero-byte keys whose name ends in '/'.
    if key.endsWith("/") {
        return false;
    }
    if !recursive {
        // Non-recursive listing uses no delimiter (passing one would silently drop
        // CommonPrefixes, which the connector's S3Object[] cannot represent), so nested
        // keys are filtered client-side: anything with a further '/' after the prefix is a
        // descendant of a sub-prefix and is skipped.
        string remainder = key.startsWith(prefix) ? key.substring(prefix.length()) : key;
        if remainder.startsWith("/") {
            remainder = remainder.substring(1);
        }
        if remainder.includes("/") {
            return false;
        }
    }
    return matchesExtensionFilter(key, includeExtensions);
}
