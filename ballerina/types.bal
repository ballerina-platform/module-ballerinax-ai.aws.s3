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

# Discriminator value selecting EC2/ECS IAM-role authentication.
public const IAM_ROLE = "IAM_ROLE";

# Static AWS credentials: an access key pair, optionally with a session token for
# temporary (STS) credentials. Use this for a user or role whose long-lived or
# temporary keys are supplied directly.
public type StaticCredentials record {|
    # The AWS access key id
    string accessKeyId;
    # The AWS secret access key
    string secretAccessKey;
    # An optional session token, required when `accessKeyId`/`secretAccessKey` are
    # temporary STS credentials; omit for long-lived IAM user keys
    string sessionToken?;
|};

# Selects EC2/ECS IAM-role authentication, where credentials are fetched from the
# instance metadata service at runtime. Use this when the loader runs on AWS
# infrastructure with an attached instance/task role and no keys are configured.
public type IamRoleCredentials record {|
    # Discriminator fixed to `IAM_ROLE`; distinguishes this from `StaticCredentials`
    IAM_ROLE credentialSource = IAM_ROLE;
|};

# The credentials used to authenticate against S3. Modelled as a union so that a
# static key pair and an IAM-role selection are mutually exclusive — an invalid
# combination (e.g. keys *and* a role) cannot be constructed.
public type Credentials StaticCredentials|IamRoleCredentials;

# Authentication and connection configuration shared by every source a loader reads.
# Maps onto the underlying `ballerinax/aws.s3` client; see the package README for the
# IAM permissions required (`s3:ListBucket`, `s3:GetObject`).
public type ConnectionConfig record {|
    # The credentials used to authenticate: a static key pair or an IAM-role selection
    Credentials auth;
    # The AWS region hosting the buckets, e.g. `us-east-1` or `eu-west-2`. Determines
    # the S3 endpoint the underlying connector talks to; defaults to `us-east-1`
    string region = "us-east-1";
|};

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
    # Defaults to `()`, meaning all supported types
    string[]? includeExtensions = ();
|};

# A single S3 bucket together with the targets to load from it. Several sources may be
# configured per loader; their documents are aggregated in the order given.
public type Source record {|
    # The name of the S3 bucket
    string bucket;
    # One or more targets (prefixes/keys) to load from the bucket.
    # Defaults to a single target covering the whole bucket, non-recursively
    Target[] targets = [{}];
|};

# Loader-wide options bounding what a single `load()` reads.
public type LoaderOptions record {|
    # The maximum number of documents a single `load()` returns. Acts as a hard cap so
    # a large bucket cannot produce an unbounded result; once reached, traversal stops
    # cleanly. Defaults to `1000`, one S3 listing page
    int maxDocuments = 1000;
    # The maximum size, in bytes, of a single object read into memory. An object larger
    # than this fails with a clear `ai:Error` rather than risking an out-of-memory
    # condition (objects are extracted entirely in memory, never written to disk).
    # Defaults to 100 MiB
    int maxObjectSize = 104857600;
|};

# A normalized S3 listing entry — the subset of an S3 object's metadata this loader
# uses. Raw string fields mirror what the S3 REST API returns; they are parsed
# leniently when the document metadata is built.
public type S3Item record {|
    # The full object key
    string key;
    # The object size in bytes as reported by S3 (a decimal string); `""` if absent
    string size = "";
    # The object's entity tag (ETag); `""` if absent
    string eTag = "";
    # The last-modified timestamp as reported by S3 (ISO-8601); `""` if absent
    string lastModified = "";
|};

# One page of an S3 object listing.
public type S3Page record {|
    # The objects on this page
    S3Item[] items;
    # Whether the listing continues beyond this page. See `S3Api` for why the
    # production implementation can only ever report a single page as truncated
    boolean truncated;
|};

# The seam through which the loader reaches S3, isolating it from the underlying
# `ballerinax/aws.s3` connector. The production implementation wraps an `s3:Client`;
# tests supply an in-memory fake. Advanced users may implement this to plug in a
# different S3 client, caching layer, or a client pointed at an S3-compatible service.
public type S3Api isolated object {
    # Lists one page of objects under a prefix.
    #
    # + bucket - The bucket to list
    # + prefix - The key prefix to list under, or `()` for the whole bucket
    # + startAfter - List keys lexicographically after this one, for pagination, or
    #                `()` for the first page
    # + maxKeys - The maximum number of keys to return in this page
    # + return - A page of objects, or an `ai:Error` on failure
    public isolated function listPage(string bucket, string? prefix, string? startAfter, int maxKeys)
        returns S3Page|ai:Error;

    # Opens a byte stream over an object's content.
    #
    # + bucket - The bucket holding the object
    # + key - The object key
    # + return - A byte stream over the object, or an `ai:Error` on failure
    public isolated function getObjectStream(string bucket, string key)
        returns stream<byte[], io:Error?>|ai:Error;
};
