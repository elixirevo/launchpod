import AppKit
// Export artwork through the public icon API; this does not copy executable code.
// Usage: export_launchpad_icon <output.iconset> [source Launchpad.app]
let appURL = URL(fileURLWithPath:CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/System/Applications/Launchpad.app")
let image = NSWorkspace.shared.icon(forFile:appURL.path)
print("workspace",image.size,image.representations.map { [$0.pixelsWide,$0.pixelsHigh] })
let destination = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let pixels = size*scale
  var rect = NSRect(x:0,y:0,width:pixels,height:pixels)
  guard let cg = image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else { fatalError("No icon representation") }
  print(pixels,cg.width,cg.height)
  let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  let context = NSGraphicsContext(bitmapImageRep:rep)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
  context.imageInterpolation = .high
  NSImage(cgImage:cg,size:NSSize(width:pixels,height:pixels)).draw(in:rect,from:.zero,operation:.copy,fraction:1)
  NSGraphicsContext.restoreGraphicsState()
  let suffix = scale == 2 ? "@2x" : ""
  try rep.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
 }
}
