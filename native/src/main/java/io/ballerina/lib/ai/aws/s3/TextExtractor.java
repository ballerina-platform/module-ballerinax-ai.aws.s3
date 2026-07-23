/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.ai.aws.s3;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;
import org.apache.poi.openxml4j.opc.OPCPackage;
import org.apache.poi.sl.extractor.SlideShowExtractor;
import org.apache.poi.xslf.usermodel.XMLSlideShow;
import org.apache.poi.xwpf.extractor.XWPFWordExtractor;
import org.apache.tika.metadata.Metadata;
import org.apache.tika.metadata.TikaCoreProperties;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.parser.Parser;
import org.apache.tika.parser.pdf.PDFParser;
import org.apache.tika.parser.pdf.PDFParserConfig;
import org.apache.tika.sax.BodyContentHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;

/**
 * Extracts plain text from documents held entirely in memory.
 *
 * <p>This loader supports PDF and the OOXML Office formats (.docx / .pptx) — the same binary
 * formats as {@code ballerina/ai}'s built-in {@code TextDataLoader}. Legacy binary Office
 * formats (.doc / .ppt / .xls) are classified and rejected on the Ballerina side, so the POI
 * HWPF/HSLF/HSSF stack is never exercised.
 *
 * <p>Unlike {@code ai:TextDataLoader}, which reads from a file path, this reads straight from
 * the in-memory bytes downloaded from S3 via a {@link ByteArrayInputStream}, so no temporary
 * file is written by this code — confidential object content need never touch disk. The
 * underlying libraries are also configured to stay in memory: PDFBox is given an explicit
 * {@link PDFParserConfig} with no main-memory limit, so it cannot fall back to a scratch file.
 * One caveat remains outside this class's control: POI honours the global system property
 * {@code org.apache.poi.openxml4j.opc.ZipPackage.useTempFilePackageParts}, which, if a host
 * sets it, makes POI spill OOXML package parts to {@code java.io.tmpdir}. It defaults to false.
 *
 * <p><b>Parser dispatch is always explicit; {@code AutoDetectParser} is never used.</b> The
 * caller has already classified the document, so the exact parser is selected here by format.
 * That matters because Tika's detection machinery probes archive formats through
 * {@code commons-compress}, which is both unnecessary and sensitive to the runtime's
 * transitive library versions.
 *
 * <p>PDFs go through Tika's {@link PDFParser}. The OOXML formats deliberately bypass Tika
 * altogether and use POI's format-specific extractors directly. Tika's {@code OOXMLParser}
 * cannot be used here: it internally runs {@code DefaultZipContainerDetector} to identify the
 * OOXML sub-format, and that detector probes TAR via {@code commons-compress}. From
 * commons-compress 1.28.0 that path calls {@code SystemProperties.getUserName(String)}, an
 * overload added in commons-lang3 3.17.0, whereas the Ballerina runtime bundles a shaded
 * commons-lang3 3.14.0 that takes precedence on the classpath — so .pptx extraction through
 * Tika fails with a {@code NoSuchMethodError}. Reading the OPC package directly through POI
 * avoids the detection pass entirely and is immune to that conflict.
 */
public final class TextExtractor {

    // A BodyContentHandler write limit of -1 means "no limit" on extracted content size.
    private static final int UNLIMITED_CONTENT_SIZE = -1;

    // Passed to PDFBox as its main-memory budget; -1 means "never spill to a temporary file".
    private static final long UNLIMITED_MAIN_MEMORY = -1L;

    private TextExtractor() {
    }

    /**
     * Extracts the textual content of a PDF document held entirely in memory.
     *
     * @param content  the raw PDF bytes
     * @param fileName the object key, used as a Tika resource-name hint
     * @return the extracted text as a {@link BString}, or a Ballerina error on failure
     */
    public static Object extractPdfText(BArray content, BString fileName) {
        try (InputStream stream = new ByteArrayInputStream(content.getBytes())) {
            Parser parser = new PDFParser();
            BodyContentHandler handler = new BodyContentHandler(UNLIMITED_CONTENT_SIZE);
            Metadata metadata = new Metadata();
            metadata.set(TikaCoreProperties.RESOURCE_NAME_KEY, fileName.getValue());
            // Pin PDFBox to memory so parsing can never spill a scratch file to disk.
            PDFParserConfig pdfConfig = new PDFParserConfig();
            pdfConfig.setMaxMainMemoryBytes(UNLIMITED_MAIN_MEMORY);
            ParseContext parseContext = new ParseContext();
            parseContext.set(PDFParserConfig.class, pdfConfig);
            parser.parse(stream, handler, metadata, parseContext);
            return StringUtils.fromString(handler.toString());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Extracts the textual content of a Word document (.docx) held entirely in memory, reading
     * the OPC package directly through POI.
     *
     * @param content  the raw .docx bytes
     * @param fileName the object key (unused by POI; kept for signature symmetry)
     * @return the extracted text as a {@link BString}, or a Ballerina error on failure
     */
    public static Object extractDocxText(BArray content, BString fileName) {
        // The extractor owns and closes the OPCPackage, so it must not also be closed here:
        // a second close makes POI log a spurious warning on every extraction.
        try (InputStream stream = new ByteArrayInputStream(content.getBytes());
             XWPFWordExtractor extractor = new XWPFWordExtractor(OPCPackage.open(stream))) {
            return StringUtils.fromString(extractor.getText());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Extracts the textual content of a PowerPoint presentation (.pptx) held entirely in
     * memory, reading the slide show directly through POI.
     *
     * @param content  the raw .pptx bytes
     * @param fileName the object key (unused by POI; kept for signature symmetry)
     * @return the extracted text as a {@link BString}, or a Ballerina error on failure
     */
    public static Object extractPptxText(BArray content, BString fileName) {
        // As above, the extractor closes the slide show it wraps.
        try (InputStream stream = new ByteArrayInputStream(content.getBytes());
             SlideShowExtractor<?, ?> extractor = new SlideShowExtractor<>(new XMLSlideShow(stream))) {
            return StringUtils.fromString(extractor.getText());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Converts any failure into a Ballerina error.
     *
     * <p>{@link Throwable} is caught rather than {@link Exception} deliberately. A Java
     * {@code Error} escaping an external function surfaces in Ballerina as a <em>panic</em>,
     * which bypasses every {@code check} in the loader and cannot be recovered by a caller —
     * defeating the package's guarantee that failures arrive as a handleable {@code ai:Error}.
     * The realistic cases are all reachable from untrusted S3 content: a {@code
     * StackOverflowError} from a deeply nested PDF object graph, an {@code OutOfMemoryError}
     * from a compression bomb, and the {@code NoSuchMethodError} class of dependency conflict
     * this class is otherwise architected to avoid.
     *
     * <p>The exception's simple class name is always included, because several POI and PDFBox
     * exceptions carry a {@code null} message and would otherwise produce an empty error.
     */
    private static Object toBallerinaError(Throwable t) {
        String message = t.getMessage();
        String detail = message != null && !message.isBlank()
                ? t.getClass().getSimpleName() + ": " + message
                : t.getClass().getSimpleName();
        return ErrorCreator.createError(StringUtils.fromString(detail));
    }
}
