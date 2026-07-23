# Ballerina AWS S3 Data Loader

[![Build](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/actions/workflows/ci.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/actions/workflows/ci.yml)
[![Trivy](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/actions/workflows/trivy-scan.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/actions/workflows/trivy-scan.yml)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/ballerina-platform/module-ballerinax-ai.aws.s3.svg?label=Last%20Commit)](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/commits/main)
[![GitHub Issues](https://img.shields.io/github/issues/ballerina-platform/ballerina-library/module/ai.aws.s3.svg?label=Open%20Issues)](https://github.com/ballerina-platform/ballerina-library/labels/module%2Fai.aws.s3)

The `ballerinax/ai.aws.s3` package provides a `TextDataLoader` that reads objects from
[AWS S3](https://aws.amazon.com/s3/) buckets and returns them as `ai:TextDocument` values, ready to
be chunked, embedded, and indexed by the [Ballerina AI](https://central.ballerina.io/ballerina/ai)
module.

It implements the `ai:DataLoader` abstraction, so it can be used anywhere an `ai:DataLoader` is
expected — for example, in a retrieval-augmented generation (RAG) ingestion pipeline.
Natively-textual objects are decoded directly, while PDF, Word (`.docx`) and PowerPoint (`.pptx`)
documents have their text extracted **in memory** with Apache Tika and Apache POI — object content
is never written to disk.

For the full API, configuration reference, supported file types, and usage guide, see the
[package documentation](ballerina/README.md).

## Limitations

Please read these before indexing a large or busy bucket. Several stem from gaps in the underlying
[`ballerinax/aws.s3`](https://central.ballerina.io/ballerinax/aws.s3/3.5.1) connector rather than
from S3 itself.

- **No pagination: a listing is capped at one page (1000 objects).** The connector never surfaces
  `IsTruncated` or `NextContinuationToken`, and its `start-after` parameter is emitted without a
  separator, corrupting the signed request — so neither pagination mechanism is usable. If a prefix
  holds more objects than fit in one page, the loader **fails with a clear error** rather than
  silently returning a partial corpus, because a quietly incomplete RAG index produces confidently
  wrong answers. Narrow the prefix or lower `maxDocuments`. Key-marker paging is already
  implemented and tested, and will work unchanged once the connector is fixed.
- **A single page is not a consistent snapshot.** S3 listings are eventually consistent and
  returned in key order. Under concurrent writes, objects added or removed during a load can be
  missed or double-counted — inherent to key-marker paging — and the one-page cap makes it more
  likely that recent writes fall outside what is read.
- **Objects are read entirely into memory,** so that no temporary file is ever written. Each object
  must therefore fit in the heap; `maxObjectSize` (default 100 MiB) bounds this, and a larger
  object produces a clear error rather than an out-of-memory crash.
- **Non-recursive filtering happens client-side.** S3's `delimiter` cannot be used, because the
  connector discards `CommonPrefixes`. `recursive: false` therefore lists **every** key under the
  prefix and discards the nested ones — on a wide prefix this wastes listing bandwidth and counts
  against the one-page cap.
- **Keys needing percent-encoding will fail** with `SignatureDoesNotMatch` — a key or prefix
  containing a space, `+`, `&`, `=`, `#`, or non-ASCII characters. The connector signs an encoded
  canonical URI but sends the raw one, and uses form encoding where SigV4 requires `%20`.
- **Legacy binary Office and spreadsheets are unsupported** (`.doc`, `.ppt`, `.xls`, `.xlsx`),
  matching `ballerina/ai`. Convert `.doc`/`.ppt` to `.docx`/`.pptx` or PDF; export spreadsheets to
  `.csv`. (`.xlsx` is excluded despite being OOXML — extracting meaningful text from a spreadsheet
  is a different problem, not a format-support gap.)
- **All buckets in one loader share one region**, since `region` is set on the connection.
- **One unreadable object fails the whole load** — deliberately, since a silently incomplete RAG
  index is worse than a failed one. Objects of unsupported *types* are skipped, not failed.
- **No `versionId` and no requester-pays support**, as neither can be expressed through the
  connector.
- **AWS endpoints only** — S3-compatible services (MinIO, LocalStack, R2) cannot be targeted.

## Issues and projects

The **Issues** and **Projects** tabs are disabled for this repository as this is part of the
Ballerina library. To report bugs, request new features, start new discussions, view project boards,
etc., visit the Ballerina library [parent repository](https://github.com/ballerina-platform/ballerina-library).

This repository only contains the source code for the package.

## Build from the source

### Prerequisites

1. Download and install Java SE Development Kit (JDK) version 21 (from one of the following locations).

   - [Oracle](https://www.oracle.com/java/technologies/downloads/)
   - [OpenJDK](https://adoptium.net/)

     > **Note:** Set the JAVA_HOME environment variable to the path name of the directory into which you installed JDK.

2. Generate a GitHub access token with read package permissions, then set the following `env` variables:

   ```shell
   export packageUser=<Your GitHub Username>
   export packagePAT=<GitHub Personal Access Token>
   ```

   > **Note:** These credentials are required because the Ballerina Gradle plugin
   > (`io.ballerina.plugin`) is published to GitHub Packages, which requires authentication even
   > for public packages. Without them the Gradle build cannot resolve the plugin. See
   > [docs/TESTING.md](docs/TESTING.md) for how to build and test using the `bal` CLI directly if
   > you do not have a token.

### Build options

Execute the commands below to build from the source.

1. To build the package:

   ```bash
   ./gradlew clean build
   ```

2. To run the tests:

   ```bash
   ./gradlew clean test
   ```

3. To run a group of tests

   ```bash
   ./gradlew clean test -Pgroups=<test_group_names>
   ```

4. To build without the tests:

   ```bash
   ./gradlew clean build -x test
   ```

5. To debug the package with a remote debugger:

   ```bash
   ./gradlew clean build -Pdebug=<port>
   ```

6. To debug with Ballerina language:

   ```bash
   ./gradlew clean build -PbalJavaDebug=<port>
   ```

7. Publish the generated artifacts to the local Ballerina central repository:

   ```bash
   ./gradlew clean build -PpublishToLocalCentral=true
   ```

8. Publish the generated artifacts to the Ballerina central repository:

   ```bash
   ./gradlew clean build -PpublishToCentral=true
   ```

## Contribute to Ballerina

As an open-source project, Ballerina welcomes contributions from the community.

For more information, go to the [contribution guidelines](https://github.com/ballerina-platform/ballerina-lang/blob/master/CONTRIBUTING.md).

## Code of conduct

All the contributors are encouraged to read the [Ballerina Code of Conduct](https://ballerina.io/code-of-conduct).

## Useful links

- Chat live with us via our [Discord server](https://discord.gg/ballerinalang).
- Post all technical questions on Stack Overflow with the [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
- For more information go to the [`ai.aws.s3` package](https://central.ballerina.io/ballerinax/ai.aws.s3).
- For example demonstrations of the usage, go to [Ballerina By Examples](https://ballerina.io/learn/by-example/).
