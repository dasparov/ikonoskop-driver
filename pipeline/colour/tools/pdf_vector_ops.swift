// pdf_vector_ops: read a PDF page with Apple's CoreGraphics (no installs needed).
//
//   pdf_vector_ops ops <pdf> <page>                 print the page's drawing operators, one per
//                                                   line ("<op> <operands>"), then the operators of
//                                                   every form XObject between "XOBJECT <name> Form"
//                                                   and "ENDXOBJECT"
//   pdf_vector_ops render <pdf> <page> <dpi> <png>  render the page to a PNG
//
// Datasheet graphs exported from Excel are vector drawings, so the operators carry the plotted
// data points exactly. CoreGraphics also handles the datasheets' (empty-password) encryption.
// Used by digitise_qe.py. Build: swiftc -O -o pdf_vector_ops pdf_vector_ops.swift
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 4, let pageNumber = Int(args[3]) else {
    fail("usage: pdf_vector_ops ops <pdf> <page> | render <pdf> <page> <dpi> <png>")
}
guard let document = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL) else { fail("cannot open \(args[2])") }
_ = document.unlockWithPassword("")
guard let page = document.page(at: pageNumber) else { fail("no page \(pageNumber)") }

func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
    var values: [CGFloat] = []
    for _ in 0..<count {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { break }
        values.append(value)
    }
    return values.reversed()
}

func emit(_ op: String, _ values: [CGFloat]) {
    print(([op] + values.map { String(format: "%.4f", $0) }).joined(separator: " "))
}

func makeOperatorTable() -> CGPDFOperatorTableRef {
    let table = CGPDFOperatorTableCreate()!
    // Callbacks are C function pointers (no captured context), hence one literal per operator.
    CGPDFOperatorTableSetCallback(table, "m") { s, _ in emit("m", popNumbers(s, 2)) }
    CGPDFOperatorTableSetCallback(table, "l") { s, _ in emit("l", popNumbers(s, 2)) }
    CGPDFOperatorTableSetCallback(table, "c") { s, _ in emit("c", popNumbers(s, 6)) }
    CGPDFOperatorTableSetCallback(table, "v") { s, _ in emit("v", popNumbers(s, 4)) }
    CGPDFOperatorTableSetCallback(table, "y") { s, _ in emit("y", popNumbers(s, 4)) }
    CGPDFOperatorTableSetCallback(table, "re") { s, _ in emit("re", popNumbers(s, 4)) }
    CGPDFOperatorTableSetCallback(table, "cm") { s, _ in emit("cm", popNumbers(s, 6)) }
    CGPDFOperatorTableSetCallback(table, "Tm") { s, _ in emit("Tm", popNumbers(s, 6)) }
    CGPDFOperatorTableSetCallback(table, "w") { s, _ in emit("w", popNumbers(s, 1)) }
    CGPDFOperatorTableSetCallback(table, "RG") { s, _ in emit("RG", popNumbers(s, 3)) }
    CGPDFOperatorTableSetCallback(table, "rg") { s, _ in emit("rg", popNumbers(s, 3)) }
    CGPDFOperatorTableSetCallback(table, "G") { s, _ in emit("RG", [CGFloat](repeating: popNumbers(s, 1).first ?? 0, count: 3)) }
    CGPDFOperatorTableSetCallback(table, "g") { s, _ in emit("rg", [CGFloat](repeating: popNumbers(s, 1).first ?? 0, count: 3)) }
    CGPDFOperatorTableSetCallback(table, "SC") { s, _ in emit("RG", popNumbers(s, 3)) }
    CGPDFOperatorTableSetCallback(table, "SCN") { s, _ in emit("RG", popNumbers(s, 3)) }
    CGPDFOperatorTableSetCallback(table, "sc") { s, _ in emit("rg", popNumbers(s, 3)) }
    CGPDFOperatorTableSetCallback(table, "scn") { s, _ in emit("rg", popNumbers(s, 3)) }
    CGPDFOperatorTableSetCallback(table, "q") { _, _ in print("q") }
    CGPDFOperatorTableSetCallback(table, "Q") { _, _ in print("Q") }
    CGPDFOperatorTableSetCallback(table, "h") { _, _ in print("h") }
    CGPDFOperatorTableSetCallback(table, "n") { _, _ in print("n") }
    CGPDFOperatorTableSetCallback(table, "S") { _, _ in print("S") }
    CGPDFOperatorTableSetCallback(table, "s") { _, _ in print("S") }
    CGPDFOperatorTableSetCallback(table, "f") { _, _ in print("f") }
    CGPDFOperatorTableSetCallback(table, "F") { _, _ in print("f") }
    CGPDFOperatorTableSetCallback(table, "f*") { _, _ in print("f") }
    CGPDFOperatorTableSetCallback(table, "B") { _, _ in print("B") }
    CGPDFOperatorTableSetCallback(table, "B*") { _, _ in print("B") }
    CGPDFOperatorTableSetCallback(table, "b") { _, _ in print("B") }
    CGPDFOperatorTableSetCallback(table, "b*") { _, _ in print("B") }
    CGPDFOperatorTableSetCallback(table, "Do") { s, _ in
        var name: UnsafePointer<CChar>? = nil
        if CGPDFScannerPopName(s, &name), let name = name { print("Do " + String(cString: name)) }
    }
    CGPDFOperatorTableSetCallback(table, "Tj") { s, _ in
        var string: CGPDFStringRef? = nil
        if CGPDFScannerPopString(s, &string), let string = string, let text = CGPDFStringCopyTextString(string) {
            print("Tj " + (text as String))
        }
    }
    CGPDFOperatorTableSetCallback(table, "Tf") { s, _ in emit("Tf", popNumbers(s, 1)) }
    CGPDFOperatorTableSetCallback(table, "TJ") { s, _ in
        var array: CGPDFArrayRef? = nil
        guard CGPDFScannerPopArray(s, &array), let array = array else { return }
        var text = ""
        for i in 0..<CGPDFArrayGetCount(array) {
            var string: CGPDFStringRef? = nil
            if CGPDFArrayGetString(array, i, &string), let string = string,
               let part = CGPDFStringCopyTextString(string) {
                text += part as String
            }
        }
        print("Tj " + text)
    }
    return table
}

func dumpOperators() {
    let table = makeOperatorTable()
    let content = CGPDFContentStreamCreateWithPage(page)
    CGPDFScannerScan(CGPDFScannerCreate(content, table, nil))
    guard let pageDictionary = page.dictionary else { return }
    var resources: CGPDFDictionaryRef? = nil
    var xobjects: CGPDFDictionaryRef? = nil
    guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources = resources,
          CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects = xobjects else { return }
    CGPDFDictionaryApplyBlock(xobjects, { key, object, _ in
        var stream: CGPDFStreamRef? = nil
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream = stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
        var subtype: UnsafePointer<CChar>? = nil
        CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
        let kind = subtype.map { String(cString: $0) } ?? "?"
        print("XOBJECT \(String(cString: key)) \(kind)")
        if kind == "Form" {
            var formResources: CGPDFDictionaryRef? = nil
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources)
            let formContent = CGPDFContentStreamCreateWithStream(stream, formResources ?? resources, content)
            CGPDFScannerScan(CGPDFScannerCreate(formContent, table, nil))
            print("ENDXOBJECT")
        }
        return true
    }, nil)
}

func render(dpi: Double, to path: String) {
    let box = page.getBoxRect(.mediaBox)
    let width = Int(box.width * dpi / 72), height = Int(box.height * dpi / 72)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: CGFloat(dpi / 72), y: CGFloat(dpi / 72))
    context.translateBy(x: -box.origin.x, y: -box.origin.y)
    context.drawPDFPage(page)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    do {
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("cannot write \(path): \(error)")
    }
}

switch args[1] {
case "ops":
    dumpOperators()
case "render":
    guard args.count == 6, let dpi = Double(args[4]) else { fail("usage: render <pdf> <page> <dpi> <png>") }
    render(dpi: dpi, to: args[5])
default:
    fail("unknown command \(args[1])")
}
