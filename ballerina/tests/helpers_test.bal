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

import ballerina/io;

// Shared test helpers.
//
// The loader reads through a concrete `s3:Client`, which cannot be substituted or redirected
// (the connector hardcodes the AWS endpoint), so `TextDataLoader.load()` itself is only
// exercised by integration testing against real S3. What the unit suite covers instead is every
// decision the loader delegates to a module-private function: classification, the prefix-walk
// filters, document construction and metadata mapping, and stream draining.

const string TEST_BUCKET = "test-bucket";

// Splits content into chunks of `chunkSize` bytes (a single chunk when `chunkSize` is 0).
isolated function chunkBytes(byte[] content, int chunkSize) returns byte[][] {
    if chunkSize <= 0 || content.length() == 0 {
        return content.length() == 0 ? [] : [content];
    }
    byte[][] chunks = [];
    int offset = 0;
    while offset < content.length() {
        int end = offset + chunkSize;
        chunks.push(content.slice(offset, end > content.length() ? content.length() : end));
        offset = end;
    }
    return chunks;
}

// A byte-stream iterator that can fail at a chosen chunk and records whether it was closed,
// so tests can prove no stream is leaked on an error path.
isolated class TestByteIterator {
    private final readonly & byte[][] chunks;
    private final int failAtIndex;
    private int index = 0;
    private boolean closed = false;

    isolated function init(byte[][] chunks, int failAtIndex = -1) {
        self.chunks = chunks.cloneReadOnly();
        self.failAtIndex = failAtIndex;
    }

    public isolated function next() returns record {|byte[] value;|}|io:Error? {
        // The chunk stays `readonly` so it is an isolated expression and may cross the lock
        // boundary; widening it to `byte[]` inside the lock would not be transferable.
        readonly & byte[] chunk;
        lock {
            if self.failAtIndex >= 0 && self.index == self.failAtIndex {
                return error io:Error("Simulated mid-read stream failure");
            }
            if self.index >= self.chunks.length() {
                return ();
            }
            chunk = self.chunks[self.index];
            self.index += 1;
        }
        return {value: chunk};
    }

    public isolated function close() returns io:Error? {
        lock {
            self.closed = true;
        }
        return ();
    }

    // Whether `close` was called — the leak assertion.
    isolated function isClosed() returns boolean {
        lock {
            return self.closed;
        }
    }
}
