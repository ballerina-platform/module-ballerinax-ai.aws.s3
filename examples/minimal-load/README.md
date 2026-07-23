# Minimal load

Loads documents from an S3 bucket and prints what came back — the smallest useful thing you can
do with the loader, and the quickest way to confirm your credentials, IAM policy, and target are
right before wiring up a full RAG pipeline.

A `Source` names a bucket and the `Target`s to read from it; this example configures a single
target covering one prefix.

For each document it prints the key, MIME type, size, ETag, and the first 200 characters of the
extracted text, so you can see that PDF/DOCX/PPTX extraction actually worked.

## Prerequisites

An S3 bucket with some documents in it, and credentials whose IAM policy allows `s3:ListBucket`
on the bucket and `s3:GetObject` on its objects. See the
[package README](../../ballerina/README.md#3-grant-the-required-iam-permissions) for a minimal
policy.

## Configuration

Create a `Config.toml` in this directory:

```toml
accessKeyId = "<ACCESS_KEY_ID>"
secretAccessKey = "<SECRET_ACCESS_KEY>"
region = "us-east-1"
bucket = "my-corpus-bucket"

# Optional: restrict to a prefix. Defaults to "", the whole bucket.
prefix = "reports/"
```

> `Config.toml` holds live credentials — it is gitignored by this repository. Do not commit it.

`region` **must match the region the bucket was created in**. A mismatch fails with an opaque
`PermanentRedirect` / `AuthorizationHeaderMalformed` error rather than anything helpful; the
bucket's region is shown in the S3 console's Buckets list.

## Run the example

The examples resolve the loader from the **local** Ballerina repository, so publish it there once
before running (from the repository root):

```bash
./gradlew clean build -PpublishToLocalCentral=true
```

If you do not have a GitHub token for the Gradle build, publish with the `bal` CLI instead:

```bash
cd ballerina && bal pack && bal push --repository=local
```

Then run the example:

```bash
cd examples/minimal-load
bal run
```

## Expected output

```
Loaded 2 document(s) from 'my-corpus-bucket'.

key       : reports/q1-summary.pdf
mimeType  : application/pdf
size      : 84213
eTag      : 9b2cf5e0a7d14f8ab3c9e1d2f4a6b8c0
characters: 4127

preview   : Q1 Summary  Revenue grew 12% year over year, driven primarily by...

key       : reports/notes.md
mimeType  : text/markdown
size      : 512
eTag      : 3f1a9c7e5b2d8460af13e6c9d0b7524e
characters: 512
preview   : # Field notes  These are the raw notes taken during the Q1 review...
```

## Notes

- The configurable is called `prefix` because that is the common case, but the underlying
  `Target` field is `path` and also accepts an **exact object key** — `path: "reports/q1.pdf"`
  loads that one object.
- `maxDocuments` is set to 20 so a large bucket cannot flood your terminal on a first run.
- `recursive: true` descends into nested prefixes. Set it to `false` to load only the keys
  directly under `prefix`.
- To run this on EC2 with an attached IAM role instead of static keys, drop the `accessKeyId`
  and `secretAccessKey` configurables and pass `auth: {credentialSource: s3:IAM_ROLE}`.
- If the prefix holds more than 1000 objects the load fails with an explicit error rather than
  returning a partial set — see [Limitations](../../ballerina/README.md#limitations).
