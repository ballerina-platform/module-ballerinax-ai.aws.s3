## Overview

This package provides an [AWS S3](https://aws.amazon.com/s3/) data loader for Ballerina AI
applications. It reads objects from S3 buckets and returns them as `ai:TextDocument` values,
ready to be chunked, embedded, and indexed for retrieval-augmented generation (RAG).

It implements the `ai:DataLoader` abstraction, so it can be used anywhere an `ai:DataLoader` is
expected and its output feeds directly into `ai:KnowledgeBase.ingest`. Natively-textual objects are
decoded directly; PDF, Word (`.docx`) and PowerPoint (`.pptx`) documents have their text extracted
**in memory** — object content is never written to disk.

## Prerequisites

### 1. Create an S3 bucket

Create a bucket and upload the documents you want to index, following the
[AWS S3 getting-started guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/GetStartedWithS3.html).

### 2. Obtain credentials

The loader authenticates in one of two ways:

- **Static credentials** — an access key pair for an IAM user or role, optionally with a session
  token for temporary (STS) credentials. See
  [Managing access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html).
- **EC2/ECS IAM role** — no keys at all; credentials are resolved from the instance metadata
  service. This works only when running on AWS infrastructure with an attached instance or task role.

### 3. Grant the required IAM permissions

The loader only ever reads. It needs exactly two actions:

| Action | Applied to | Why |
|---|---|---|
| `s3:ListBucket` | the **bucket** ARN | to enumerate keys under a prefix |
| `s3:GetObject` | the **object** ARN (`/*`) | to download object content |

A minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucketContents",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::my-corpus-bucket"
    },
    {
      "Sid": "ReadObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::my-corpus-bucket/*"
    }
  ]
}
```

To restrict access to a single prefix, narrow the `GetObject` resource to
`arn:aws:s3:::my-corpus-bucket/reports/*` and add an `s3:prefix` condition to the `ListBucket`
statement.

## Quickstart

### Step 1: Import the module

```ballerina
import ballerinax/ai.aws.s3;
```

### Step 2: Create a loader

```ballerina
s3:TextDataLoader loader = check new (
    {
        accessKeyId: "<ACCESS_KEY_ID>",
        secretAccessKey: "<SECRET_ACCESS_KEY>",
        region: "us-east-1"
    },
    [
        {
            bucket: "my-corpus-bucket",
            targets: [{path: "reports/", recursive: true}]
        }
    ]
);
```

### Step 3: Load the documents

```ballerina
import ballerina/ai;

ai:Document[]|ai:Document documents = check loader.load();
```

`load()` returns a **bare `ai:Document`** when exactly one object is resolved and an
`ai:Document[]` otherwise — the same contract as `ai`'s built-in `TextDataLoader`. Both shapes are
accepted directly by `ingest`:

```ballerina
check knowledgeBase.ingest(documents);
```

## Configuration

### Connection

The loader's first argument is either an
[`s3:ConnectionConfig`](https://central.ballerina.io/ballerinax/aws.s3/latest#ConnectionConfig)
— the `ballerinax/aws.s3` connector's own configuration, from which the loader builds a client —
or an already-configured `s3:Client` you want it to reuse.

| Field | Type | Default | Description |
|---|---|---|---|
| `accessKeyId` | `string?` | — | Access key id; required for static auth |
| `secretAccessKey` | `string?` | — | Secret access key; required for static auth |
| `sessionToken` | `string?` | — | Session token, required for temporary (STS) credentials |
| `region` | `string?` | `"us-east-1"` | **Must match the region each bucket was created in** — a mismatch fails with an opaque `PermanentRedirect` error. The bucket's region is shown in the S3 console's Buckets list |
| `authType` | `AWS_STATIC_AUTH\|EC2_IAM_ROLE` | `AWS_STATIC_AUTH` | Selects static keys or EC2/ECS instance-metadata credentials |
| `timeout`, `retryConfig`, `proxy`, `secureSocket`, … | — | — | The standard Ballerina HTTP client options the connector accepts |

```ballerina
import ballerinax/aws.s3 as awsS3;

// Static credentials
awsS3:ConnectionConfig config = {
    accessKeyId: "AKIA...",
    secretAccessKey: "...",
    region: "us-east-1"
};

// Temporary (STS) credentials
awsS3:ConnectionConfig config = {
    accessKeyId: "ASIA...",
    secretAccessKey: "...",
    sessionToken: "...",
    region: "us-east-1"
};

// EC2/ECS IAM role - credentials come from instance metadata
awsS3:ConnectionConfig config = {authType: awsS3:EC2_IAM_ROLE, region: "us-east-1"};
```

**Prefer the IAM-role form in production** when running on AWS: it needs no long-lived keys in
configuration at all. The examples use static credentials only because they must run anywhere.

#### Reusing an existing client

Passing a ready `s3:Client` lets you share one client across several loaders, or apply HTTP
options (retries, proxy, TLS settings) the loader itself does not surface:

```ballerina
awsS3:Client s3Client = check new ({
    accessKeyId: "AKIA...",
    secretAccessKey: "...",
    region: "us-east-1",
    timeout: 120,
    retryConfig: {count: 3, interval: 2}
});

s3:TextDataLoader loader = check new (s3Client, [{bucket: "my-corpus-bucket"}]);
```

### Sources and targets

A `Source` names a bucket and the `Target`s to read from it. Several sources may be configured in
one loader; their documents are aggregated in the order given.

| `Target` field | Type | Default | Description |
|---|---|---|---|
| `path` | `string` | `""` | An object key or key prefix. See "How paths are resolved" below |
| `recursive` | `boolean` | `false` | Whether to descend into nested prefixes |
| `includeExtensions` | `string[]?` | `()` (all types) | Case-insensitive extension allowlist; a leading dot is optional |

```ballerina
{
    bucket: "my-corpus-bucket",
    targets: [
        {path: "reports/2026/", recursive: true, includeExtensions: [".pdf", "docx"]},
        {path: "policies/handbook.md"}
    ]
}
```

### How paths are resolved

S3 has no folders — only keys that happen to contain `/`. So:

- `""` (the default) or a value ending in `/` is treated as a **prefix**.
- Anything else is tried as an **exact key** first and, if no such key exists, treated as a prefix.
- Keys ending in `/` (the zero-byte "folder" objects the S3 console creates) are always skipped.
- With `recursive: false`, only keys directly under the prefix are loaded — a key whose remainder
  after the prefix contains another `/` is skipped.

An unsupported file type named **explicitly** as an exact key is an error. An unsupported file
found while **walking a prefix** is skipped with a logged warning, so one stray image cannot fail
an entire corpus load.

> **Collision to be aware of:** if a bucket holds *both* an object at key `reports` and objects
> under `reports/`, then `path: "reports"` resolves the single object and ignores the folder
> entirely — the exact-key match wins and there is no error. Write `path: "reports/"` when you
> mean the prefix.

### Loader options (`LoaderOptions`)

| Field | Type | Default | Description |
|---|---|---|---|
| `maxDocuments` | `int` | `1000` | Hard cap on the documents returned by one `load()`, so a large bucket cannot produce an unbounded result |
| `maxObjectSize` | `int` | `104857600` (100 MiB) | Largest single object read into memory; a bigger object fails with a clear error rather than risking an out-of-memory condition |

```ballerina
s3:TextDataLoader loader = check new (connectionConfig, sources,
        {maxDocuments: 250, maxObjectSize: 20 * 1024 * 1024});
```

## Supported file types

The supported set matches `ballerina/ai`'s built-in `TextDataLoader` exactly, plus the
natively-textual formats S3 buckets commonly hold.

| Type | Extensions | How the text is obtained |
|---|---|---|
| Markup | `md`, `markdown`, `html`, `htm` | Decoded verbatim (tags and all); stripping is the chunker's job |
| Plain text | `txt`, `text`, `csv`, `tsv`, `json`, `xml`, `yaml`, `yml`, `log`, `ini`, `conf`, `properties`, `css`, `js`, `ts` | Decoded directly as UTF-8 |
| PDF | `pdf` | Apache Tika `PDFParser` + PDFBox, in memory |
| Word | `docx` | Apache POI `XWPFWordExtractor`, in memory |
| PowerPoint | `pptx` | Apache POI `SlideShowExtractor`, in memory |
| **Legacy binary Office** | `doc`, `ppt` | **Not supported** — convert to `.docx` / `.pptx` or PDF |
| **Spreadsheets** | `xls`, `xlsx` | **Not supported** — tabular extraction is out of scope; export to `.csv` |
| Anything else | images, audio, unknown binary | Skipped (an error if named explicitly) |

Object metadata is attached to every document: `fileName` (the key), `mimeType`, `fileSize`,
`modifiedAt`, plus the open fields `bucket`, `key`, and `eTag`.

## Limitations

Please read these before indexing a large or busy bucket. Several stem from gaps in the underlying
[`ballerinax/aws.s3`](https://central.ballerina.io/ballerinax/aws.s3/3.5.1) connector rather than
from S3 itself.

- **No pagination: a listing is capped at one page (1000 objects).** The connector never surfaces
  `IsTruncated` or `NextContinuationToken`, and its `start-after` parameter is emitted without a
  separator, which corrupts the signed request — so neither pagination mechanism is usable. If a
  prefix holds more objects than fit in one page, the loader **fails with a clear error** rather
  than silently returning a partial corpus, because a quietly incomplete RAG index produces
  confidently wrong answers. Key-marker paging is already implemented and tested, and will work
  unchanged once the connector is fixed.

  Two consequences worth being explicit about:
  - **Setting `maxDocuments` above 1000 cannot help** — the listing itself is the limit, not the
    document cap. To load more than one page's worth, split the work across narrower `path`s.
  - **Setting `maxDocuments` below the page size suppresses the error.** Reaching the cap is
    treated as a deliberate bound, so the load succeeds with a bounded subset rather than failing,
    and does so silently. That is the right behaviour when you *want* a sample, and the wrong one
    if you assumed you got everything — so prefer narrowing `path` when completeness matters.
- **A single page is not a consistent snapshot.** S3 listings are eventually consistent and
  returned in key order. Under concurrent writes, objects added or removed during a load can be
  missed or double-counted — inherent to key-marker paging — and the one-page cap makes it more
  likely that recent writes fall outside what is read.
- **Objects are read entirely into memory.** Extraction reads from an in-memory buffer so that no
  temporary file is ever written, but each object must therefore fit in the heap. `maxObjectSize`
  (default 100 MiB) bounds this; a larger object is a clear error, not an out-of-memory crash.
- **Non-recursive filtering happens client-side.** S3's `delimiter` cannot be used, because the
  connector discards `CommonPrefixes` and `S3Object[]` cannot represent them. `recursive: false`
  therefore lists **every** key under the prefix and discards the nested ones. On a wide prefix
  this wastes listing bandwidth and counts against the one-page cap — prefer a narrower `path`.
- **Keys needing percent-encoding will fail.** An object key or prefix containing a space, `+`,
  `&`, `=`, `#`, or non-ASCII characters fails with `SignatureDoesNotMatch`. The connector signs
  an encoded canonical URI but sends the raw one, and uses form encoding (a space becomes `+`)
  where SigV4 requires `%20`. Such keys are routine in S3, so check yours before indexing; there
  is no workaround short of an upstream fix or renaming the objects.
- **An exact key is resolved by listing its prefix.** If more than 1000 keys share the exact key
  as a prefix and the key itself sorts beyond the first page, the lookup misses and silently
  falls back to a prefix walk. Rare, but it follows from the one-page cap above.
- **Legacy binary Office and spreadsheets are unsupported.** `.doc`, `.ppt`, `.xls` and `.xlsx`
  are recognised only so they can be rejected with a format-specific message or skipped. This
  matches `ballerina/ai`. Convert `.doc`/`.ppt` to `.docx`/`.pptx` or PDF; export spreadsheets to
  `.csv`, which is read as text. (Note `.xlsx` is unsupported despite being OOXML like the
  supported `.docx`/`.pptx` — extracting meaningful text from a spreadsheet is a different
  problem, not a format-support gap.)
- **One unreadable object fails the whole load.** If an object is deleted between being listed
  and being downloaded, or its content cannot be decoded or parsed, the entire `load()` returns an
  error rather than skipping it. This is deliberate — a silently incomplete RAG index is worse
  than a failed one — but it means a corpus in flux may need a retry. (Objects of *unsupported
  types* are skipped, not failed; this applies to genuine read/parse failures.)
- **No `versionId`.** Pinning a reproducible corpus to specific object versions is not possible:
  the connector's `getObject` takes no `versionId` parameter.
- **No requester-pays support.** Cross-account requester-pays buckets will fail, because the
  connector cannot send the `x-amz-request-payer` header (only `x-amz-meta-*` headers can be set).
- **AWS endpoints only.** The connector hardcodes `https://` and `amazonaws.com` with no endpoint
  override, so S3-compatible services (MinIO, LocalStack, Cloudflare R2) cannot be targeted.
- **All buckets in one loader share one region**, since the region is set on the connection. A
  bucket in a different region fails with an opaque AWS redirect error; use one loader per region.

## Examples

The `ai.aws.s3` connector provides practical examples illustrating usage in various scenarios.

1. [Minimal load](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/tree/main/examples/minimal-load)
   — load documents from a bucket and inspect what came back.
2. [RAG pipeline](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/tree/main/examples/rag-pipeline)
   — load a corpus, ingest it into a knowledge base, and answer questions over it.
