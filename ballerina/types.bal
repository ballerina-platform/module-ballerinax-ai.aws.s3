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

# A rule selecting what to load from a bucket. S3 has no real folders, so `path` is
# interpreted against key prefixes (see the README's "How paths are resolved").
public type Target record {|
    # The object key or key prefix to load. A value ending in `/`, or the empty string
    # (the whole bucket), is treated as a prefix; any other value is tried first as an
    # exact key and, on a miss, as a prefix. Defaults to `""`, the whole bucket
    string path = "";
    # Whether a prefix is traversed into nested "sub-folders". When `false` (the
    # default) only keys directly under the prefix are loaded — keys whose remainder
    # after the prefix contains a further `/` are skipped
    boolean recursive = false;
    # Case-insensitive extension allowlist applied to keys found while walking a prefix
    # (a leading dot is optional, e.g. `pdf` and `.PDF` both match `report.pdf`).
    # An explicitly named exact key is always loaded regardless of this list.
    #
    # Filtering happens *after* listing, so this reduces how many documents are returned but
    # not how many keys are listed: a prefix holding 5000 images and 40 PDFs still exceeds the
    # one-page listing limit even when filtered to `["pdf"]`. Narrow `path` for that.
    # An empty array behaves like `()` — everything is allowed.
    # Defaults to `()`, meaning all supported types
    string[]? includeExtensions = ();
|};

# A single S3 bucket together with the targets to load from it. Several sources may be
# configured per loader; their documents are aggregated in the order given.
public type Source record {|
    # The name of the S3 bucket. It must live in the region set on `ConnectionConfig`, which
    # is shared by every source — a bucket in a different region fails with an opaque AWS
    # redirect error, so use one loader per region
    string bucket;
    # One or more targets (prefixes/keys) to load from the bucket, read in the order given.
    # Targets are not de-duplicated against each other: if two targets both match an object
    # (say `reports/` and `reports/q1.pdf`), it is loaded once per matching target, which
    # would index the same text twice. Keep targets disjoint.
    # Defaults to a single target covering the whole bucket, non-recursively
    Target[] targets = [{}];
|};

# Loader-wide options bounding what a single load reads.
public type LoaderOptions record {|
    # The maximum number of documents a single load returns. Acts as a hard cap so
    # a large bucket cannot produce an unbounded result; once reached, traversal stops
    # cleanly. Note that this bounds the document *count*, not total memory: the loaded
    # documents are all retained until the load returns, so peak memory is bounded by
    # `maxDocuments` times the extracted text size. Defaults to `1000`, one S3 listing page
    int maxDocuments = 1000;
    # The maximum size, in bytes, of a single object read into memory. An object larger
    # than this fails with a clear `ai:Error` rather than risking an out-of-memory
    # condition (objects are extracted entirely in memory, never written to disk).
    # Extraction transiently needs roughly twice this, since the bytes are copied across
    # the Java boundary, plus room for the extracted text. Defaults to 100 MiB
    int maxObjectSize = 104857600;
|};
