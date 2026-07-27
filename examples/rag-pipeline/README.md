# RAG pipeline

Loads a document corpus out of S3, chunks and embeds it into a vector knowledge base, and
answers a question over it — the end-to-end path the loader exists to serve.

A `Source` names a bucket and the `Target`s to read from it; this example uses a single target
with an extension allowlist.

The point of interest is how little glue is needed: `load()` returns exactly the type
`ai:KnowledgeBase.ingest` accepts, so the loader's output pipes straight in.

```ballerina
ai:Document[]|ai:Document documents = check loader.load();
check knowledgeBase.ingest(documents);
```

Chunking is left on `ai:AUTO`, which picks a chunker per document from its MIME type. That works
because the loader sets a clean `text/markdown` / `text/html` rather than passing S3's
`Content-Type` through — `ai`'s chunker selection matches those strings exactly, so a stray
`; charset=utf-8` would silently downgrade markdown to generic chunking.

## Prerequisites

1. An S3 bucket holding the documents to index, and credentials whose IAM policy allows
   `s3:ListBucket` on the bucket and `s3:GetObject` on its objects. See the
   [package README](../../ballerina/README.md#3-grant-the-required-iam-permissions) for a minimal
   policy.
2. An embedding provider. This example uses `ai:getDefaultEmbeddingProvider()`, the WSO2-hosted
   default, which requires the Ballerina AI runtime configuration described in the
   [`ballerina/ai` documentation](https://central.ballerina.io/ballerina/ai). To use a different
   provider, replace that one line with your own `ai:EmbeddingProvider`.

## Configuration

Create a `Config.toml` in this directory:

```toml
accessKeyId = "<ACCESS_KEY_ID>"
secretAccessKey = "<SECRET_ACCESS_KEY>"
region = "us-east-1"
bucket = "my-corpus-bucket"

# Optional: restrict to a prefix. Defaults to "", the whole bucket.
prefix = "handbook/"

# The question asked once the corpus is indexed.
question = "What is the policy on remote work?"

# Required by ai:getDefaultEmbeddingProvider(). Without this the run fails at the
# embedding step. This table must come AFTER the plain keys above — in TOML, every
# key following a table header belongs to that table.
[ballerina.ai.wso2ProviderConfig]
serviceUrl = "<SERVICE_URL>"
accessToken = "<ACCESS_TOKEN>"
```

> `Config.toml` holds live credentials — it is gitignored by this repository. Do not commit it.

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
cd examples/rag-pipeline
bal run
```

## Expected output

```
Loaded documents from S3.
Ingested the corpus into the knowledge base.

Question: What is the policy on remote work?

Top 2 matching passage(s):

  from  : handbook/policies.md
  score : 0.8814
  text  : ## Remote work  Employees may work remotely up to three days per week...

  from  : handbook/onboarding.pdf
  score : 0.7421
  text  : New joiners should agree a working pattern with their manager during...
```

## Notes

- The configurable is called `prefix` because that is the common case, but the underlying
  `Target` field is `path` and also accepts an **exact object key**.
- `includeExtensions` restricts the load to `.pdf`, `.md`, `.txt` and `.docx`, so unrelated
  objects under the prefix are not embedded. Anything unsupported found while walking the target
  is skipped with a warning rather than failing the run.
- The loader reads and embeds the **whole** matching corpus, paginating across all listing pages.
  There is no document cap, so a very large prefix produces a correspondingly large in-memory
  result — narrow `prefix` if that is a concern.
- **Chunks stay traceable to their object.** The loader records `bucket`, `key` and `eTag` as open
  metadata fields, and `ai`'s chunkers carry document metadata onto each chunk — which is why the
  output above can name the file each passage came from.
- The vector store here is in-memory, so the index is rebuilt on every run. Swap in a persistent
  `ai:VectorStore` to keep it between runs.
