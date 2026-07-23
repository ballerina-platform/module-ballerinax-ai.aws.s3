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
import ballerina/log;

// S3's ListObjectsV2 caps a single page at 1000 keys; the loader always requests the
// maximum so a full page is a reliable "possibly truncated" signal.
const int MAX_KEYS_PER_PAGE = 1000;

# A data loader that reads objects from AWS S3 buckets as text for a RAG ingestion
# pipeline. It implements `ai:DataLoader`, so its `load()` output feeds directly into
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

    private final S3Api s3api;
    private final readonly & Source[] sources;
    private final int maxDocuments;
    private final int maxObjectSize;

    # Initializes the AWS S3 data loader.
    #
    # + s3 - Either a `ConnectionConfig` (the common case — the loader builds an S3 client
    #        from it) or a ready `S3Api` implementation (an advanced/testing seam)
    # + sources - One or more buckets, each with the targets (prefixes/keys) to load
    # + options - Loader-wide options: the document cap and the in-memory size ceiling
    # + return - An `ai:Error` if the configuration is invalid or the client cannot be built
    public isolated function init(@display {label: "Connection Config"} ConnectionConfig|S3Api s3,
            @display {label: "Data Sources"} Source[] sources,
            @display {label: "Loader Options"} LoaderOptions options = {}) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the AWS S3 data loader");
        }
        if options.maxDocuments < 1 {
            return error ai:Error("maxDocuments must be at least 1");
        }
        if options.maxObjectSize < 1 {
            return error ai:Error("maxObjectSize must be at least 1");
        }
        self.s3api = s3 is S3Api ? s3 : check buildS3Api(s3);
        self.sources = sources.cloneReadOnly();
        self.maxDocuments = options.maxDocuments;
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
                if documents.length() >= self.maxDocuments {
                    break;
                }
                ai:Document[] loaded =
                    check self.loadTarget(src.bucket, target, self.maxDocuments - documents.length());
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
    private isolated function loadTarget(string bucket, Target target, int budget)
            returns ai:Document[]|ai:Error {
        string path = target.path;
        if path == "" || path.endsWith("/") {
            return self.loadPrefix(bucket, path, target.recursive, target.includeExtensions, budget);
        }
        S3Item? exact = check self.findExactKey(bucket, path);
        if exact is S3Item {
            return [check self.loadExactKey(bucket, exact)];
        }
        // Exact-key miss: treat the value as a prefix instead.
        return self.loadPrefix(bucket, path, target.recursive, target.includeExtensions, budget);
    }

    // Resolves an exact key by listing under it and looking for an identical key. Listing
    // (rather than a HEAD/GET probe) avoids downloading an object merely to test existence.
    private isolated function findExactKey(string bucket, string key) returns S3Item?|ai:Error {
        S3Page page = check self.s3api.listPage(bucket, key, (), MAX_KEYS_PER_PAGE);
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
                    string `'${bucket}': text extraction for legacy binary Microsoft Office documents ` +
                    string `(.doc, .ppt, .xls, .xlsx) is not supported`);
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

    // Lists a prefix and loads its supported objects, paginating with key-marker paging.
    // The loop advances by the last key seen and stops on the last page, a satisfied budget,
    // a zero-item page, or a repeated marker — so it can never spin forever.
    private isolated function loadPrefix(string bucket, string prefix, boolean recursive,
            string[]? includeExtensions, int budget) returns ai:Document[]|ai:Error {
        ai:Document[] documents = [];
        string? marker = ();
        string? effectivePrefix = prefix == "" ? () : prefix;
        while true {
            S3Page page = check self.s3api.listPage(bucket, effectivePrefix, marker, MAX_KEYS_PER_PAGE);
            foreach S3Item item in page.items {
                if documents.length() >= budget {
                    return documents;
                }
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
            if documents.length() >= budget {
                break; // budget satisfied; no need to page further
            }
            if page.items.length() == 0 {
                break; // GUARD: a truncated but empty page cannot advance the marker
            }
            string nextMarker = page.items[page.items.length() - 1].key;
            if nextMarker == marker {
                // GUARD: the marker did not advance, so paging cannot make progress. The
                // listing is genuinely truncated and unreadable with this connector.
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix == "" ? "" : string ` under prefix '${prefix}'`) +
                    string ` is truncated and cannot be fully read. Narrow the prefix or lower ` +
                    string `'maxDocuments'.`);
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
                log:printWarn("Skipping an unsupported legacy Office object: text extraction for " +
                        ".doc/.ppt/.xls/.xlsx is not supported", bucket = bucket, key = item.key);
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
        stream<byte[], io:Error?> objStream = check self.s3api.getObjectStream(bucket, item.key);
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
