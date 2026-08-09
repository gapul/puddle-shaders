import AppKit
import Metal

// Renders one frame of a wallpaper shader to a PNG, the way Puddle would: the contract preamble
// prepended, quoted includes spliced in, the same uniform layout bound to buffer(0).
//
//   swiftc -O -o render-preview tools/render-preview/main.swift
//   ./render-preview <preamble.metal> <shader.metal> <out.png> [width] [height] [time]

struct Uniforms {
    var time: Float
    var frame: UInt32
    var resolution: SIMD2<Float>
    var userCount: UInt32
    var version: UInt32
    var reserved: SIMD2<Float>
    var cursor: SIMD2<Float>
    var reserved2: SIMD2<Float>
    var reserved3: SIMD2<Float>
}

/// Quoted includes, resolved relative to the including file — Metal's runtime compiler has no
/// include path, so Puddle splices them itself and so does this.
func read(_ url: URL, included: inout Set<URL>) throws -> String {
    let url = url.standardizedFileURL
    var out: [String] = []

    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard
            trimmed.hasPrefix("#include"),
            let start = trimmed.firstIndex(of: "\""),
            let end = trimmed.lastIndex(of: "\""),
            start < end
        else {
            out.append(line)
            continue
        }

        let target = URL(
            fileURLWithPath: String(trimmed[trimmed.index(after: start)..<end]),
            relativeTo: url.deletingLastPathComponent()
        ).standardizedFileURL

        if included.insert(target).inserted {
            out.append(try read(target, included: &included))
        }
    }

    return out.joined(separator: "\n")
}

let arguments = CommandLine.arguments
let preamble = try String(contentsOf: URL(fileURLWithPath: arguments[1]), encoding: .utf8)
var included = Set<URL>()
let source = try read(URL(fileURLWithPath: arguments[2]), included: &included)
let output = URL(fileURLWithPath: arguments[3])
let width = arguments.count > 4 ? Int(arguments[4])! : 960
let height = arguments.count > 5 ? Int(arguments[5])! : 600
let time = arguments.count > 6 ? Float(arguments[6])! : 8

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: "\(preamble)\n\(source)", options: nil)

let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "wallpaperVertex")
descriptor.fragmentFunction = library.makeFunction(name: "wallpaperMain")
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
texture.usage = [.renderTarget, .shaderRead]
let target = device.makeTexture(descriptor: texture)!

var uniforms = Uniforms(
    time: time,
    frame: UInt32(time * 24),
    resolution: SIMD2(Float(width), Float(height)),
    userCount: 2,
    version: 4,
    // Dark appearance, 1 pixel per point.
    reserved: SIMD2(0, 1),
    // Pointer parked well outside the frame.
    cursor: SIMD2(-10_000, -10_000),
    // Mid-afternoon, Reduce Motion off.
    reserved2: SIMD2(15, 0),
    reserved3: .zero
)
// user[0] = workspace 3 (palette), user[1] = not covered.
var user: [Float] = [3, 0]

let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = target
pass.colorAttachments[0].loadAction = .clear
pass.colorAttachments[0].storeAction = .store

let queue = device.makeCommandQueue()!
let buffer = queue.makeCommandBuffer()!
let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
encoder.setRenderPipelineState(pipeline)
encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
encoder.setFragmentBytes(&user, length: MemoryLayout<Float>.stride * user.count, index: 1)
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
encoder.endEncoding()
buffer.commit()
buffer.waitUntilCompleted()

var pixels = [UInt8](repeating: 0, count: width * height * 4)
target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

// Metal hands back BGRA; the bitmap wants RGBA.
for i in stride(from: 0, to: pixels.count, by: 4) {
    pixels.swapAt(i, i + 2)
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: width * 4,
    bitsPerPixel: 32
)!
pixels.withUnsafeBufferPointer {
    bitmap.bitmapData!.update(from: $0.baseAddress!, count: pixels.count)
}

try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("wrote", output.lastPathComponent)
