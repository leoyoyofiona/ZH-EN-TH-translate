import AppKit
import Foundation

let appDisplayName = "多国语言同声翻译"
let supportedLanguageLabels = ["中文", "英文", "泰文", "俄文", "意大利文", "日文", "法文", "德文", "西班牙文", "韩文"]

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OfflineInterpreter.BrandAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG."])
    }

    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func drawCapsule(_ rect: NSRect, text: String, background: NSColor, textColor: NSColor, fontSize: CGFloat, weight: NSFont.Weight = .semibold) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    background.setFill()
    path.fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let size = attributed.size()
    let textRect = NSRect(
        x: rect.midX - size.width / 2,
        y: rect.midY - size.height / 2 + 1,
        width: size.width,
        height: size.height
    )
    attributed.draw(in: textRect)
}

func drawParagraph(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, lineHeight: CGFloat = 1.1) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineHeightMultiple = lineHeight

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]

    NSAttributedString(string: text, attributes: attributes).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = 10
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let arrowLength: CGFloat = 22
    let arrowAngle: CGFloat = .pi / 7
    let left = CGPoint(x: end.x - cos(angle - arrowAngle) * arrowLength, y: end.y - sin(angle - arrowAngle) * arrowLength)
    let right = CGPoint(x: end.x - cos(angle + arrowAngle) * arrowLength, y: end.y - sin(angle + arrowAngle) * arrowLength)

    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: left)
    head.move(to: end)
    head.line(to: right)
    head.lineWidth = 10
    head.lineCapStyle = .round
    color.setStroke()
    head.stroke()
}

func symbolImage(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        return nil
    }

    let tinted = NSImage(size: image.size)
    tinted.lockFocus()
    color.set()
    image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceIn, fraction: 1)
    tinted.unlockFocus()
    return tinted
}

func makeIcon(size: CGFloat) -> NSImage {
    let canvasSize = NSSize(width: size, height: size)
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let rect = NSRect(origin: .zero, size: canvasSize)
    let background = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    background.addClip()

    NSGradient(colors: [color(0x0F172A), color(0x1D4ED8), color(0x22C55E)])?.draw(in: rect, angle: -38)

    color(0xFFFFFF, alpha: 0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: -size * 0.08, y: size * 0.58, width: size * 0.56, height: size * 0.40)).fill()
    color(0x93C5FD, alpha: 0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.44, y: -size * 0.06, width: size * 0.52, height: size * 0.48)).fill()

    let glassRect = NSRect(x: size * 0.24, y: size * 0.24, width: size * 0.52, height: size * 0.52)
    let glass = NSBezierPath(roundedRect: glassRect, xRadius: size * 0.14, yRadius: size * 0.14)
    color(0xFFFFFF, alpha: 0.22).setFill()
    glass.fill()
    color(0xFFFFFF, alpha: 0.34).setStroke()
    glass.lineWidth = 2.5
    glass.stroke()

    if let arrows = symbolImage("arrow.left.arrow.right.circle.fill", pointSize: size * 0.23, weight: .bold, color: color(0x0F172A, alpha: 0.92)) {
        let symbolRect = NSRect(x: size * 0.325, y: size * 0.325, width: size * 0.35, height: size * 0.35)
        arrows.draw(in: symbolRect)
    }

    drawCapsule(NSRect(x: size * 0.10, y: size * 0.68, width: size * 0.24, height: size * 0.12), text: "中", background: color(0xF8FAFC, alpha: 0.90), textColor: color(0x0F172A), fontSize: size * 0.075, weight: .bold)
    drawCapsule(NSRect(x: size * 0.67, y: size * 0.68, width: size * 0.23, height: size * 0.12), text: "EN", background: color(0xDBEAFE, alpha: 0.94), textColor: color(0x1D4ED8), fontSize: size * 0.060, weight: .bold)
    drawCapsule(NSRect(x: size * 0.38, y: size * 0.10, width: size * 0.24, height: size * 0.12), text: "TH", background: color(0xDCFCE7, alpha: 0.94), textColor: color(0x15803D), fontSize: size * 0.060, weight: .bold)

    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: size * 0.21, yRadius: size * 0.21)
    color(0xFFFFFF, alpha: 0.20).setStroke()
    border.lineWidth = 6
    border.stroke()

    return image
}

func makeBackground(size: NSSize, icon: NSImage) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: size)
    NSGradient(colors: [color(0xF8FAFC), color(0xEEF4FF), color(0xF8FAFC)])?.draw(in: rect, angle: -90)

    color(0xBFDBFE, alpha: 0.46).setFill()
    NSBezierPath(ovalIn: NSRect(x: size.width - 340, y: size.height - 250, width: 360, height: 260)).fill()
    color(0xFBCFE8, alpha: 0.34).setFill()
    NSBezierPath(ovalIn: NSRect(x: -120, y: size.height - 300, width: 380, height: 280)).fill()
    color(0xA7F3D0, alpha: 0.24).setFill()
    NSBezierPath(ovalIn: NSRect(x: -80, y: -120, width: 320, height: 240)).fill()

    let panel = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: size.width - 84, height: size.height - 84), xRadius: 34, yRadius: 34)
    color(0xFFFFFF, alpha: 0.58).setFill()
    panel.fill()
    color(0xFFFFFF, alpha: 0.90).setStroke()
    panel.lineWidth = 2
    panel.stroke()

    icon.draw(in: NSRect(x: 84, y: size.height - 180, width: 96, height: 96))

    drawParagraph(appDisplayName, in: NSRect(x: 196, y: size.height - 160, width: 560, height: 60), font: NSFont.systemFont(ofSize: 40, weight: .bold), color: color(0x0F172A))
    drawParagraph("支持 中文 / 英文 / 泰文 / 俄文 / 意大利文 / 日文 / 法文 / 德文 / 西班牙文 / 韩文", in: NSRect(x: 198, y: size.height - 214, width: 820, height: 54), font: NSFont.systemFont(ofSize: 18, weight: .medium), color: color(0x334155), lineHeight: 1.25)
    drawParagraph("Drag the app into Applications to install", in: NSRect(x: 84, y: size.height - 300, width: 520, height: 42), font: NSFont.systemFont(ofSize: 28, weight: .semibold), color: color(0x1D4ED8))
    drawParagraph("实时双栏字幕，优先离线翻译，不走强制订阅。", in: NSRect(x: 84, y: size.height - 344, width: 560, height: 52), font: NSFont.systemFont(ofSize: 16, weight: .regular), color: color(0x475569), lineHeight: 1.25)

    let leftSlot = NSBezierPath(roundedRect: NSRect(x: 150, y: 148, width: 176, height: 176), xRadius: 32, yRadius: 32)
    color(0xFFFFFF, alpha: 0.80).setFill()
    leftSlot.fill()
    color(0xD1E3FF, alpha: 0.95).setStroke()
    leftSlot.lineWidth = 2
    leftSlot.stroke()

    let rightSlot = NSBezierPath(roundedRect: NSRect(x: size.width - 326, y: 148, width: 176, height: 176), xRadius: 32, yRadius: 32)
    color(0xFFFFFF, alpha: 0.82).setFill()
    rightSlot.fill()
    color(0xD1E3FF, alpha: 0.95).setStroke()
    rightSlot.lineWidth = 2
    rightSlot.stroke()

    drawArrow(from: CGPoint(x: 360, y: 236), to: CGPoint(x: size.width - 362, y: 236), color: color(0x3B82F6, alpha: 0.70))

    drawCapsule(NSRect(x: 174, y: 102, width: 128, height: 42), text: "App", background: color(0x0F172A, alpha: 0.92), textColor: .white, fontSize: 20, weight: .bold)
    drawCapsule(NSRect(x: size.width - 302, y: 102, width: 128, height: 42), text: "Applications", background: color(0x1D4ED8, alpha: 0.92), textColor: .white, fontSize: 18, weight: .bold)

    drawParagraph("macOS 26+ • signed build recommended for system-audio capture", in: NSRect(x: 84, y: 58, width: 720, height: 24), font: NSFont.systemFont(ofSize: 14, weight: .medium), color: color(0x64748B))

    return image
}

func makeLanguageOverview(size: NSSize, icon: NSImage) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: size)
    NSGradient(colors: [color(0xF8FAFC), color(0xEEF4FF), color(0xFFFFFF)])?.draw(in: rect, angle: -90)

    color(0xDBEAFE, alpha: 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: size.width - 380, y: size.height - 300, width: 420, height: 320)).fill()
    color(0xDCFCE7, alpha: 0.40).setFill()
    NSBezierPath(ovalIn: NSRect(x: -140, y: -120, width: 360, height: 260)).fill()

    let panel = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: size.width - 108, height: size.height - 108), xRadius: 32, yRadius: 32)
    color(0xFFFFFF, alpha: 0.72).setFill()
    panel.fill()
    color(0xFFFFFF, alpha: 0.95).setStroke()
    panel.lineWidth = 2
    panel.stroke()

    icon.draw(in: NSRect(x: 84, y: size.height - 184, width: 90, height: 90))
    drawParagraph(appDisplayName, in: NSRect(x: 196, y: size.height - 154, width: 580, height: 54), font: NSFont.systemFont(ofSize: 38, weight: .bold), color: color(0x0F172A))
    drawParagraph("已接入 10 种常用语言，可在同一窗口里直接切换源语言与目标语言。", in: NSRect(x: 198, y: size.height - 204, width: 820, height: 42), font: NSFont.systemFont(ofSize: 18, weight: .medium), color: color(0x475569), lineHeight: 1.2)

    let startX: CGFloat = 96
    let startY: CGFloat = size.height - 310
    let horizontalGap: CGFloat = 26
    let verticalGap: CGFloat = 24
    let itemWidth: CGFloat = 170
    let itemHeight: CGFloat = 60
    let columns = 5

    for (index, label) in supportedLanguageLabels.enumerated() {
        let row = index / columns
        let column = index % columns
        let x = startX + CGFloat(column) * (itemWidth + horizontalGap)
        let y = startY - CGFloat(row) * (itemHeight + verticalGap)
        let backgroundColor: NSColor
        let textColor: NSColor

        switch index % 5 {
        case 0:
            backgroundColor = color(0xDBEAFE, alpha: 0.92)
            textColor = color(0x1D4ED8)
        case 1:
            backgroundColor = color(0xDCFCE7, alpha: 0.92)
            textColor = color(0x15803D)
        case 2:
            backgroundColor = color(0xFCE7F3, alpha: 0.92)
            textColor = color(0xBE185D)
        case 3:
            backgroundColor = color(0xFEF3C7, alpha: 0.92)
            textColor = color(0xB45309)
        default:
            backgroundColor = color(0xEDE9FE, alpha: 0.92)
            textColor = color(0x6D28D9)
        }

        drawCapsule(NSRect(x: x, y: y, width: itemWidth, height: itemHeight), text: label, background: backgroundColor, textColor: textColor, fontSize: 23, weight: .bold)
    }

    drawParagraph("系统音频 / 麦克风输入  •  双栏滚动字幕  •  导出 Word / TXT / Markdown", in: NSRect(x: 96, y: 112, width: 860, height: 28), font: NSFont.systemFont(ofSize: 16, weight: .semibold), color: color(0x334155))
    drawParagraph("中文、英文、泰文优先走本地离线链路；其余语种按系统资源情况自动切换。", in: NSRect(x: 96, y: 84, width: 860, height: 26), font: NSFont.systemFont(ofSize: 14, weight: .medium), color: color(0x64748B))

    return image
}

let args = CommandLine.arguments
let root = args.count > 1 ? URL(fileURLWithPath: args[1], isDirectory: true) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let iconPNGURL = root.appendingPathComponent("Resources/AppIcon-base.png")
let backgroundURL = root.appendingPathComponent("Resources/dmg-background.png")
let overviewURL = root.appendingPathComponent("docs/screenshots/language-support-overview.png")

let icon = makeIcon(size: 1024)
let background = makeBackground(size: NSSize(width: 1200, height: 720), icon: icon)
let overview = makeLanguageOverview(size: NSSize(width: 1600, height: 900), icon: icon)

try savePNG(icon, to: iconPNGURL)
try savePNG(background, to: backgroundURL)
try savePNG(overview, to: overviewURL)
print("Generated brand assets in \(root.path)/Resources")
