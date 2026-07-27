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
import ballerina/test;

// These tests run real fixture files — a genuine PDF, Word .docx, PowerPoint .pptx, and a legacy
// binary .doc — through `buildDocument`, the function the loader calls once an object's bytes are
// in hand. They are what stops a Tika, PDFBox or POI version bump from silently breaking text
// extraction: a dependency change that broke a parser would fail here rather than quietly
// yielding empty documents in production.
//
// The three binary fixtures are deliberately **multi-unit**: the PDF has two pages, the .docx two
// paragraphs, and the .pptx two slides, with the two asserted phrases placed in *separate* units.
// `assertOrderedPhrases` then checks both are present and that the first precedes the second, so an
// extractor that dropped the trailing page/slide/paragraph, or concatenated units out of order,
// fails here rather than passing on the first unit alone.

// Asserts `first` and `second` both appear in `content`, with `first` strictly before `second`.
isolated function assertOrderedPhrases(string content, string first, string second, string label) {
    int? firstAt = content.indexOf(first);
    int? secondAt = content.indexOf(second);
    test:assertTrue(firstAt !is (), label + ": first unit missing; extracted: " + content);
    test:assertTrue(secondAt !is (), label + ": second unit missing (dropped?); extracted: " + content);
    if firstAt is int && secondAt is int {
        test:assertTrue(firstAt < secondAt,
                label + ": units extracted out of order; extracted: " + content);
    }
}

// Runs a fixture through document construction exactly as the loader does after draining.
isolated function buildFromFixture(string fixture, string key, string size = "1024",
        string lastModified = "2026-01-15T10:30:00Z", string eTag = "abc123")
        returns ai:TextDocument?|ai:Error {
    byte[]|io:Error content = io:fileReadBytes("tests/resources/" + fixture);
    if content is io:Error {
        return error ai:Error("Failed to read the test fixture " + fixture, content);
    }
    return buildDocument(content, TEST_BUCKET, key, size, lastModified, eTag);
}

// Returns the text content of a document.
isolated function contentOf(ai:Document doc) returns string {
    anydata content = doc.content;
    return content is string ? content : "";
}

@test:Config {}
isolated function testExtractTextFromPdfFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.pdf", "corpus/sample.pdf").ensureType();
    string content = contentOf(doc);
    // Page 1 phrase then page 2 phrase — proves both pages are concatenated, in order.
    assertOrderedPhrases(content, "Ballerina S3 loader PDF fixture",
            "Extracted from a real PDF document", "PDF");
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "application/pdf");
    test:assertEquals(metadata["key"], "corpus/sample.pdf");
}

@test:Config {}
isolated function testExtractTextFromDocxFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.docx", "corpus/sample.docx").ensureType();
    string content = contentOf(doc);
    // Paragraph 1 phrase then paragraph 2 phrase — the two now sit in separate <w:p> elements,
    // so an extractor returning only the first paragraph would fail this.
    assertOrderedPhrases(content, "Ballerina S3 loader DOCX fixture",
            "Extracted from a real Word document", "DOCX");
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
}

@test:Config {}
isolated function testExtractTextFromPptxFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.pptx", "corpus/sample.pptx").ensureType();
    string content = contentOf(doc);
    // Slide 1 title then slide 2 body — proves both slides are concatenated, in order.
    assertOrderedPhrases(content, "S3 Loader PPTX Fixture",
            "Extracted from a real PowerPoint presentation", "PPTX");
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType,
            "application/vnd.openxmlformats-officedocument.presentationml.presentation");
}

@test:Config {}
isolated function testExtractTextFromMarkdownFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.md", "corpus/sample.md").ensureType();
    string content = contentOf(doc);
    // Markdown is passed through verbatim, exactly as `ai`'s own loader does — the markup is
    // stripped later by the Markdown chunker, not here.
    test:assertTrue(content.includes("# S3 Loader Markdown Fixture"),
            "Markdown must be decoded verbatim, including its markup; got: " + content);
    test:assertTrue(content.includes("- first bullet"), "Markdown body missing; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/markdown");
}

@test:Config {}
isolated function testExtractTextFromHtmlFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.html", "corpus/sample.html").ensureType();
    string content = contentOf(doc);
    // HTML is likewise decoded verbatim, tags included.
    test:assertTrue(content.includes("<h1>Heading of the HTML fixture</h1>"),
            "HTML must be decoded verbatim, including its tags; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/html");
}

@test:Config {}
isolated function testExtractTextFromPlainTextFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.txt", "corpus/sample.txt").ensureType();
    string content = contentOf(doc);
    test:assertTrue(content.includes("Ballerina S3 loader plain text fixture"),
            "Plain text decoding failed; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/plain");
}

@test:Config {}
isolated function testLegacyDocFixtureIsNotExtracted() returns error? {
    // A genuine legacy binary Word document. Classification must reject it before any parser
    // sees it, so `buildDocument` returns () and the caller decides whether that is a skip
    // (prefix walk) or an error (explicitly named key).
    ai:TextDocument? doc = check buildFromFixture("legacy.doc", "corpus/legacy.doc");
    test:assertTrue(doc is (), "A legacy .doc must not produce a document");
    test:assertEquals(classify("corpus/legacy.doc", ()), UNSUPPORTED_OFFICE,
            "A legacy .doc must classify as unsupported Office, driving the format-specific error");
}

@test:Config {}
isolated function testCorruptPdfSurfacesAsExtractionError() {
    // Bytes with a PDF header but a garbage body: the parser must fail, and that failure must
    // arrive as a wrapped ai:Error naming the object — never as a panic.
    byte[] corrupt = "%PDF-1.4\nnot actually a pdf body".toBytes();
    ai:TextDocument?|ai:Error result =
        buildDocument(corrupt, TEST_BUCKET, "corpus/broken.pdf", "31", "", "");
    test:assertTrue(result is ai:Error, "A corrupt PDF must fail rather than yield an empty document");
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to extract text from"),
                "Unexpected message: " + result.message());
        test:assertTrue(result.message().includes("corpus/broken.pdf"),
                "The error must name the key: " + result.message());
        test:assertTrue(result.message().includes(TEST_BUCKET), "The error must name the bucket");
    }
}

@test:Config {}
isolated function testUnsupportedBinaryYieldsNoDocument() returns error? {
    ai:TextDocument? doc = check buildDocument([1, 2, 3], TEST_BUCKET, "a.png", "3", "", "");
    test:assertTrue(doc is (), "An unsupported type must yield no document, signalling a skip");
}

@test:Config {}
isolated function testUtf8ContentIsDecodedCorrectly() returns error? {
    string body = "héllo wörld — ünïcode ✓";
    ai:TextDocument doc =
        check buildDocument(body.toBytes(), TEST_BUCKET, "utf8.txt", "0", "", "").ensureType();
    test:assertEquals(contentOf(doc), body, "UTF-8 content must round-trip exactly");
}

@test:Config {}
isolated function testInvalidUtf8SurfacesAsError() {
    // A lone continuation byte is not valid UTF-8.
    ai:TextDocument?|ai:Error result =
        buildDocument([0xC3, 0x28, 0xA9], TEST_BUCKET, "bad.txt", "3", "", "");
    test:assertTrue(result is ai:Error, "Undecodable content must surface as an error");
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to decode text content"),
                "Unexpected message: " + result.message());
    }
}

// ---------------------------------------------------------------------------
// Metadata mapping
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testMetadataMapping() returns error? {
    ai:TextDocument doc = check buildDocument("# Title".toBytes(), TEST_BUCKET, "docs/report.md",
            "1234", "2026-01-15T10:30:00Z", "abc123").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.fileName, "docs/report.md");
    test:assertEquals(metadata["bucket"], TEST_BUCKET);
    test:assertEquals(metadata["key"], "docs/report.md");
    test:assertEquals(metadata["eTag"], "abc123");
    test:assertEquals(metadata.fileSize, <decimal>1234);
    // A markdown key must carry a clean `text/markdown` (no charset parameter), which is what
    // `ai`'s `guessChunker` matches on exactly.
    test:assertEquals(metadata.mimeType, "text/markdown");
    test:assertTrue(metadata.modifiedAt !is (), "A valid timestamp must map to modifiedAt");
}

@test:Config {}
isolated function testMetadataToleratesMalformedLastModified() returns error? {
    ai:TextDocument doc = check buildDocument("body".toBytes(), TEST_BUCKET, "docs/a.txt",
            "10", "not-a-timestamp", "e").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertTrue(metadata.modifiedAt is (),
            "An unparseable timestamp must be omitted rather than failing the load");
    test:assertEquals(metadata.fileName, "docs/a.txt", "The rest of the metadata must survive");
}

@test:Config {}
isolated function testMetadataToleratesNonNumericSize() returns error? {
    ai:TextDocument doc = check buildDocument("body".toBytes(), TEST_BUCKET, "docs/a.txt",
            "not-a-number", "", "").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertTrue(metadata.fileSize is (),
            "A non-numeric size must be omitted rather than failing the load");
    test:assertEquals(contentOf(doc), "body");
}

@test:Config {}
isolated function testAbsentMetadataFieldsAreOmitted() returns error? {
    // The connector reports every S3Object field as optional and substitutes "" when absent.
    ai:TextDocument doc =
        check buildDocument("body".toBytes(), TEST_BUCKET, "a.txt", "", "", "").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertTrue(metadata.fileSize is (), "An absent size must be omitted");
    test:assertTrue(metadata.modifiedAt is (), "An absent timestamp must be omitted");
    test:assertTrue(metadata["eTag"] is (), "An absent ETag must be omitted, not stored as empty");
    test:assertEquals(metadata["bucket"], TEST_BUCKET, "The bucket must still be recorded");
}

@test:Config {}
isolated function testHtmlMimeTypeIsCleanForChunkerRouting() returns error? {
    ai:TextDocument doc =
        check buildDocument("<h1>Hi</h1>".toBytes(), TEST_BUCKET, "page.html", "0", "", "").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/html");
}

// ---------------------------------------------------------------------------
// Classification table
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testClassificationMatchesAiSupportedTypes() {
    // The supported set must match `ballerina/ai`'s built-in TextDataLoader exactly:
    // pdf, docx, pptx, html, htm, md (plus the natively-textual types S3 buckets hold).
    test:assertEquals(classify("a.pdf", ()), PDF);
    test:assertEquals(classify("a.docx", ()), DOCX);
    test:assertEquals(classify("a.pptx", ()), PPTX);
    test:assertEquals(classify("a.html", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.htm", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.md", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.txt", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.csv", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.json", ()), PLAIN_TEXT);
    // Legacy binary and spreadsheet Office formats are unsupported, matching `ai`.
    test:assertEquals(classify("a.doc", ()), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("a.ppt", ()), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("a.xls", ()), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("a.xlsx", ()), UNSUPPORTED_OFFICE);
    // Anything else is skipped.
    test:assertEquals(classify("a.png", ()), UNSUPPORTED);
    test:assertEquals(classify("noextension", ()), UNSUPPORTED);
}

@test:Config {}
isolated function testClassificationIsCaseInsensitive() {
    // S3 keys are frequently uppercase; `ai`'s own loader mishandles this, so we must not.
    test:assertEquals(classify("REPORT.PDF", ()), PDF);
    test:assertEquals(classify("Notes.MD", ()), PLAIN_TEXT);
    test:assertEquals(classify("Deck.PPTX", ()), PPTX);
    test:assertEquals(classify("OLD.DOC", ()), UNSUPPORTED_OFFICE);
}

@test:Config {}
isolated function testClassificationPrefersMimeTypeWhenSupplied() {
    test:assertEquals(classify("noextension", "application/pdf"), PDF);
    test:assertEquals(classify("noextension", "text/plain"), PLAIN_TEXT);
    test:assertEquals(classify("noextension", "application/msword"), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("noextension",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), UNSUPPORTED_OFFICE);
}
