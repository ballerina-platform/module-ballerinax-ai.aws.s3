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
import ballerina/jballerina.java;
import ballerina/time;

# How an object's content is turned into text, derived from its key/MIME type. Matches
# the file types supported by `ballerina/ai`'s built-in `TextDataLoader` exactly:
# `md`/`html`/`htm` and other natively-textual types are decoded directly; `pdf` and the
# OOXML formats `docx`/`pptx` are extracted via Apache Tika; legacy binary Office formats
# are recognised only so they can be rejected or skipped.
enum DocumentKind {
    // Inherently textual (md/html/htm/txt/csv/json/xml/yaml/…); decoded from its bytes.
    PLAIN_TEXT,
    // A PDF document; text extracted via Tika's PDFParser.
    PDF,
    // An OOXML document (.docx/.pptx); text extracted via Tika's OOXMLParser.
    OOXML,
    // A legacy binary Office document (.doc/.ppt/.xls/.xlsx). Like `ballerina/ai`, this
    // loader does not support these: they are skipped in prefix walks and rejected with
    // a format-specific error when named explicitly.
    UNSUPPORTED_OFFICE,
    // Cannot be represented as text (images, audio, unknown binary); skipped.
    UNSUPPORTED
}

# Builds an `ai:TextDocument` from an object's downloaded bytes, decoding natively-textual
# content directly and extracting `pdf`/`docx`/`pptx` via Apache Tika. Returns `()` when the
# object cannot be represented as text (legacy Office, images, unknown binary), signalling
# the caller to skip or reject it.
#
# + content - The object's raw bytes (already drained from the S3 stream)
# + bucket - The source bucket, recorded in metadata
# + key - The object key, used for classification and recorded in metadata
# + size - The object size as reported by S3 (a decimal string; parsed leniently)
# + lastModified - The last-modified timestamp reported by S3 (ISO-8601; parsed leniently)
# + eTag - The object's ETag, recorded in metadata
# + return - The text document, `()` if the object is not text, or an `ai:Error` on failure
isolated function buildDocument(byte[] content, string bucket, string key, string size,
        string lastModified, string eTag) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName: key};
    // A clean, parameter-free MIME type derived from the key extension. `ai`'s
    // `guessChunker` matches `text/markdown`/`text/html` *exactly*, so a `; charset=...`
    // suffix (which S3's Content-Type often carries) must never reach it.
    string? mimeType = mimeTypeForExtension(getExtension(key));
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    int|error parsedSize = int:fromString(size);
    if parsedSize is int {
        metadata.fileSize = <decimal>parsedSize;
    }
    time:Utc? modifiedAt = toUtc(lastModified);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }
    // bucket/key/eTag are recorded as open metadata fields (quoted keys), the only way to
    // extend `ai:Metadata`, whose declared fields are a fixed set.
    metadata["bucket"] = bucket;
    metadata["key"] = key;
    if eTag != "" {
        metadata["eTag"] = eTag;
    }

    match classify(key, ()) {
        PLAIN_TEXT => {
            string|error text = string:fromBytes(content);
            if text is error {
                return error ai:Error(
                    string `Failed to decode text content of '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        PDF => {
            string|error text = extractPdfText(content, key);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        OOXML => {
            string|error text = extractOoxmlText(content, key);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
    }
    return ();
}

# Extracts plain text from a PDF document using Apache Tika's `PDFParser`, reading directly
# from the in-memory bytes (no temporary file). `fileName` is passed as a Tika resource-name
# hint. Dispatch is explicit — `AutoDetectParser` is never used — so Tika's container
# detection (and its version-sensitive `commons-compress` probing) never runs.
isolated function extractPdfText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractPdfText"
} external;

# Extracts plain text from an OOXML document (`.docx`/`.pptx`) using Apache Tika's
# `OOXMLParser`, reading directly from the in-memory bytes (no temporary file). `fileName`
# is passed as a Tika resource-name hint. Dispatch is explicit — `AutoDetectParser` is never
# used — so only the OOXML container path runs.
isolated function extractOoxmlText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractOoxmlText"
} external;

# Classifies an object by how its text is obtained, using MIME type (when known) then the
# key extension. S3 object listings carry no Content-Type, so in practice classification is
# by extension; the `mimeType` parameter is honoured when a caller has one.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string mime = (mimeType ?: "").toLowerAscii();
    string extension = getExtension(fileName);
    if mime.startsWith("text/") || (mime != "" && TEXT_MIME_TYPES.indexOf(mime) !is ())
            || TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    if mime == "application/pdf" || extension == "pdf" {
        return PDF;
    }
    if (mime != "" && OOXML_MIME_TYPES.indexOf(mime) !is ()) || OOXML_EXTENSIONS.indexOf(extension) !is () {
        return OOXML;
    }
    // Legacy binary Office formats are recognised solely so they can be rejected with a
    // clear message (named keys) or skipped (prefix walks) — this loader, like
    // `ballerina/ai`, extracts text from PDF and OOXML only.
    if (mime != "" && LEGACY_OFFICE_MIME_TYPES.indexOf(mime) !is ())
            || LEGACY_OFFICE_EXTENSIONS.indexOf(extension) !is () {
        return UNSUPPORTED_OFFICE;
    }
    return UNSUPPORTED;
}

# Reports whether a key names a legacy binary Office document (.doc/.ppt/.xls/.xlsx), which
# this loader does not support.
isolated function isUnsupportedOfficeDocument(string fileName) returns boolean =>
    classify(fileName, ()) == UNSUPPORTED_OFFICE;

# Drains a byte stream fully into memory, enforcing a size ceiling, and closes the stream on
# every exit path (normal completion, ceiling exceeded, or a mid-read error) so no stream is
# ever leaked. An object exceeding `maxBytes` fails with a clear `ai:Error` rather than
# risking an out-of-memory condition.
#
# + objStream - The stream to drain (consumed and closed by this function)
# + maxBytes - The maximum total size permitted, in bytes
# + bucket - The source bucket, for error messages
# + key - The object key, for error messages
# + return - The object's bytes, or an `ai:Error` if a read fails or the ceiling is exceeded
isolated function drainStream(stream<byte[], io:Error?> objStream, int maxBytes, string bucket, string key)
        returns byte[]|ai:Error {
    byte[] content = [];
    int total = 0;
    while true {
        record {|byte[] value;|}|io:Error? next = objStream.next();
        if next is io:Error {
            closeQuietly(objStream);
            return error ai:Error(
                string `Failed to read object '${key}' in bucket '${bucket}': ${next.message()}`, next);
        }
        if next is () {
            break;
        }
        total += next.value.length();
        if total > maxBytes {
            closeQuietly(objStream);
            return error ai:Error(string `Object '${key}' in bucket '${bucket}' exceeds the configured ` +
                string `maximum size of ${maxBytes} bytes and was not read into memory.`);
        }
        content.push(...next.value);
    }
    io:Error? closeResult = objStream.close();
    if closeResult is io:Error {
        return error ai:Error(
            string `Failed to close the stream for object '${key}' in bucket '${bucket}': ${closeResult.message()}`,
            closeResult);
    }
    return content;
}

# Closes a stream, ignoring any close error. Used on error paths where the original error
# is the one worth surfacing.
isolated function closeQuietly(stream<byte[], io:Error?> objStream) {
    io:Error? closeResult = objStream.close();
    if closeResult is io:Error {
        // Intentionally ignored: a close failure must not mask the read/ceiling error.
    }
}

# Returns the lower-cased key extension (without the dot), or `""` if none.
isolated function getExtension(string fileName) returns string {
    int? lastDotIndex = fileName.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return fileName.substring(lastDotIndex + 1).toLowerAscii();
}

# Reports whether a key passes the extension allowlist (`()`/empty matches all). A leading
# dot on an allowed entry is optional and matching is case-insensitive.
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

# Parses an ISO 8601 timestamp into `time:Utc`, or `()` if absent/blank/unparseable.
isolated function toUtc(string dateTime) returns time:Utc? {
    if dateTime.trim() == "" {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

# Maps a key extension to a clean, parameter-free MIME type, or `()` when unknown. The
# `text/markdown` and `text/html` values are set precisely so `ai`'s `guessChunker` routes
# markup to its Markdown/HTML chunkers.
isolated function mimeTypeForExtension(string extension) returns string? => MIME_TYPES_BY_EXTENSION[extension];

# MIME types (outside the `text/` family) treated as natively textual.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

# Key extensions treated as natively textual (decoded directly, matching `ai`'s handling of
# `md`/`html`/`htm` and the natively-textual types S3 buckets hold constantly).
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
];

# OOXML MIME types whose text is extracted via Tika's OOXMLParser.
final readonly & string[] OOXML_MIME_TYPES = [
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
];

# OOXML key extensions whose text is extracted via Tika's OOXMLParser.
final readonly & string[] OOXML_EXTENSIONS = ["docx", "pptx"];

# Legacy binary Office MIME types, recognised only to reject/skip (unsupported, matching `ai`).
final readonly & string[] LEGACY_OFFICE_MIME_TYPES = [
    "application/msword",
    "application/vnd.ms-powerpoint",
    "application/vnd.ms-excel"
];

# Legacy binary Office key extensions, recognised only to reject/skip (unsupported).
final readonly & string[] LEGACY_OFFICE_EXTENSIONS = ["doc", "ppt", "xls", "xlsx"];

# Extension-to-MIME-type table used for document metadata and chunker routing.
final readonly & map<string> MIME_TYPES_BY_EXTENSION = {
    "md": "text/markdown",
    "markdown": "text/markdown",
    "html": "text/html",
    "htm": "text/html",
    "txt": "text/plain",
    "text": "text/plain",
    "log": "text/plain",
    "ini": "text/plain",
    "conf": "text/plain",
    "properties": "text/plain",
    "csv": "text/csv",
    "tsv": "text/tab-separated-values",
    "json": "application/json",
    "xml": "application/xml",
    "yaml": "application/yaml",
    "yml": "application/yaml",
    "css": "text/css",
    "js": "text/javascript",
    "ts": "application/typescript",
    "pdf": "application/pdf",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
};
