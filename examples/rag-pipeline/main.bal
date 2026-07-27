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
import ballerinax/ai.aws.s3;
import ballerinax/aws.s3 as awsS3;

// Supplied via Config.toml — never hard-code credentials.
configurable string accessKeyId = ?;
configurable string secretAccessKey = ?;
configurable awsS3:Region region = awsS3:US_EAST_1;
configurable string bucket = ?;
configurable string prefix = "";

// The question asked of the corpus once it has been indexed.
configurable string question = "What does this corpus say?";

public function main() returns error? {
    // 1. Load the corpus out of S3. Only the document types the loader supports are read;
    //    anything else under the prefix is skipped with a warning.
    s3:TextDataLoader loader = check new (
        {auth: {accessKeyId, secretAccessKey}, region},
        [
            {
                bucket,
                targets: [{path: prefix, recursive: true, includeExtensions: [".pdf", ".md", ".txt", ".docx"]}]
            }
        ]
    );

    ai:Document[]|ai:Document documents = check loader.load();
    io:println("Loaded documents from S3.");

    // 2. Build a knowledge base. `AUTO` chunking picks a chunker per document from its MIME
    //    type — which is why the loader sets a clean `text/markdown` or `text/html` rather
    //    than passing S3's Content-Type through verbatim.
    ai:InMemoryVectorStore vectorStore = check new ();
    ai:Wso2EmbeddingProvider embeddingProvider = check ai:getDefaultEmbeddingProvider();
    ai:VectorKnowledgeBase knowledgeBase = new (vectorStore, embeddingProvider, ai:AUTO);

    // 3. Ingest. `load()`'s return type is exactly what `ingest` accepts, so it pipes
    //    straight in with no adaptation.
    check knowledgeBase.ingest(documents);
    io:println("Ingested the corpus into the knowledge base.");

    // 4. Retrieve the passages most relevant to the question.
    ai:QueryMatch[] matches = check knowledgeBase.retrieve(question, 3);

    io:println("");
    io:println("Question: ", question);
    io:println("");
    if matches.length() == 0 {
        io:println("No relevant passages were found.");
        return;
    }

    io:println(string `Top ${matches.length()} matching passage(s):`);
    foreach ai:QueryMatch queryMatch in matches {
        ai:Chunk chunk = queryMatch.chunk;
        ai:Metadata metadata = chunk.metadata ?: {};
        anydata key = metadata["key"];
        string content = chunk.content is string ? <string>chunk.content : "";
        io:println("");
        io:println("  from  : ", key is string ? key : "(unknown)");
        io:println("  score : ", queryMatch.similarityScore);
        io:println("  text  : ", content.length() > 300 ? content.substring(0, 300) + "..." : content);
    }
}
