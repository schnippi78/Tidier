import AppKit

// Renders Tidier's 1024×1024 app icon: a squircle with a fresh blue gradient and a
// floating white menu-bar pill holding the chevron (collapse) + three dots (hidden items).

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// Apple-style squircle (superellipse), inset a touch from the canvas edge.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width/2, b = rect.height/2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i)/CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2/n), ct)
        let y = cy + b * copysign(pow(abs(st), 2/n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

let inset: CGFloat = 92
let body = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let squirclePath = squircle(body)

// No baked outer shadow — macOS adds its own in the Dock; a baked one reads as a dark ring.
// Diagonal blue gradient fill, clipped to the squircle.
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(74, 160, 255), rgb(43, 120, 240), rgb(20, 150, 210)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY), options: [])
// Soft top highlight for depth.
let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.midY + 40), options: [])
ctx.restoreGState()

// The white menu-bar pill.
let pillH: CGFloat = 232
let pill = CGRect(x: 168, y: (S - pillH)/2, width: S - 2*168, height: pillH)
let pillPath = CGPath(roundedRect: pill, cornerWidth: pillH/2, cornerHeight: pillH/2, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(10, 40, 90, 0.28))
ctx.addPath(pillPath)
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

let brand = rgb(33, 111, 232)   // Tidier blue

// Chevron-left (the collapse toggle), stroked with round joints.
ctx.saveGState()
let cxp = pill.minX + 150, cyp = pill.midY
let arm: CGFloat = 66
let chev = CGMutablePath()
chev.move(to: CGPoint(x: cxp + arm*0.7, y: cyp + arm))
chev.addLine(to: CGPoint(x: cxp - arm*0.35, y: cyp))
chev.addLine(to: CGPoint(x: cxp + arm*0.7, y: cyp - arm))
ctx.addPath(chev)
ctx.setStrokeColor(brand)
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// Three dots (the tucked-away items).
let dotR: CGFloat = 34
let firstX = pill.minX + 360
let gap: CGFloat = 118
for i in 0..<3 {
    let x = firstX + CGFloat(i)*gap
    ctx.setFillColor(brand)
    ctx.fillEllipse(in: CGRect(x: x - dotR, y: cyp - dotR, width: 2*dotR, height: 2*dotR))
}

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png"
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
