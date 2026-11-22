// HexShot — yerel, internete hiçbir şey göndermeyen basit ekran görüntüsü aracı.
// Ağ kodu yoktur: görüntü yalnızca panoya kopyalanır veya seçtiğiniz dosyaya kaydedilir.

import Cocoa
import ScreenCaptureKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - Model

enum Tool: Int, CaseIterable {
    case select, pen, line, arrow, rect, ellipse, marker, text, blur, step

    var symbol: String {
        switch self {
        case .select: "crop"
        case .pen: "pencil"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .marker: "highlighter"
        case .text: "textformat"
        case .blur: "eye.slash"
        case .step: "1.circle"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .line: "l"
        case .arrow: "a"
        case .rect: "r"
        case .ellipse: "e"
        case .marker: "m"
        case .text: "t"
        case .blur: "b"
        case .step: "n"
        }
    }

    /// Araç çubuğundaki sırası: 1–9, onuncu araç 0.
    var numberKey: String { rawValue == 9 ? "0" : "\(rawValue + 1)" }

    var title: String {
        let name: String
        switch self {
        case .select: name = "Seçim / taşı / boyutlandır"
        case .pen: name = "Kalem"
        case .line: name = "Çizgi"
        case .arrow: name = "Ok"
        case .rect: name = "Dikdörtgen"
        case .ellipse: name = "Elips"
        case .marker: name = "Fosforlu kalem"
        case .text: name = "Metin"
        case .blur: name = "Bulanıklaştır (pikselleştir)"
        case .step: name = "Numaralı adım"
        }
        return "\(name)  (\(numberKey))"
    }
}

struct Annotation {
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var number = 0
    var filled = false

    /// Kalemle çizilen şeklin başı ile sonu birleşmiş mi?
    var isClosedLoop: Bool {
        guard points.count > 8, let a = points.first, let b = points.last else { return false }
        let box = rect
        return hypot(a.x - b.x, a.y - b.y) < 30 && box.width > 20 && box.height > 20
    }

    var rect: CGRect {
        if points.count > 2 {
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let a = points.first ?? .zero, b = points.last ?? .zero
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var isMeaningful: Bool {
        switch tool {
        case .pen, .marker: return points.count > 1
        case .text: return !text.isEmpty
        case .step: return true
        default: return rect.width > 2 || rect.height > 2
        }
    }
}

enum Style {
    static let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    static let widths: [CGFloat] = [2, 4, 8]
    static func textFont(_ w: CGFloat) -> NSFont { .systemFont(ofSize: 12 + w * 2.5, weight: .semibold) }
    static func textAttributes(_ w: CGFloat, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return [.font: textFont(w), .foregroundColor: color, .shadow: shadow]
    }
}

enum Handle: CaseIterable {
    case tl, t, tr, r, br, b, bl, l
    func point(in s: CGRect) -> CGPoint {
        switch self {
        case .tl: CGPoint(x: s.minX, y: s.maxY)
        case .t: CGPoint(x: s.midX, y: s.maxY)
        case .tr: CGPoint(x: s.maxX, y: s.maxY)
        case .r: CGPoint(x: s.maxX, y: s.midY)
        case .br: CGPoint(x: s.maxX, y: s.minY)
        case .b: CGPoint(x: s.midX, y: s.minY)
        case .bl: CGPoint(x: s.minX, y: s.minY)
        case .l: CGPoint(x: s.minX, y: s.midY)
        }
    }
}

// MARK: - Overlay

final class OverlayWindow: NSWindow {
    static var live = 0
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        OverlayWindow.live += 1
    }
    deinit { MainActor.assumeIsolated { OverlayWindow.live -= 1 } }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView, NSTextFieldDelegate {
    enum Drag { case none, select(CGPoint), move(CGPoint, CGRect), resize(Handle, CGRect), draw }

    weak var controller: CaptureController?
    let image: NSImage
    let cgImage: CGImage
    private lazy var pixelated: NSImage = makePixelated()

    var selection: CGRect?
    /// Tam ekrana geçmeden önceki alan; tam ekran düğmesine tekrar basınca buna dönülür.
    var previousSelection: CGRect?
    var isFullScreenSelection: Bool { selection == bounds }
    var annotations: [Annotation] = []
    var current: Annotation?
    var tool: Tool = .select
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fillShapes = false
    private var drag: Drag = .none
    private var toolbar: ToolbarView?
    /// Seçerek çek modunda ⌘A / Boşluk ile tam ekran seçilebilir; Alan seç modunda yalnızca alan.
    var allowFullScreen = true
    private var textField: NSTextField?
    private var textWidth: CGFloat = 4

    static var live = 0
    deinit { MainActor.assumeIsolated { OverlayView.live -= 1 } }

    init(frame: CGRect, cgImage: CGImage) {
        OverlayView.live += 1
        self.cgImage = cgImage
        self.image = NSImage(cgImage: cgImage, size: frame.size)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Geri döndürülmesi çok zor, hafif bulanıklaştırma (GPU / Core Image kullanmaz, diske önbellek yazmaz):
    /// 1) Ekran, 20pt'lik her blok TEK piksel olacak şekilde küçültülür → blok içindeki ayrıntı kalıcı olarak kaybolur
    ///    (bir blok birden fazla harfi kaplar),
    /// 2) her bloğun rengine rastgele sapma eklenir → blok-eşleştirme saldırılarını (Depix vb.) bozar,
    /// 3) çizerken yumuşak büyütülür → bulanık görünüm.
    /// Bellek: 5K ekranda bile ~60 KB.
    private func makePixelated() -> NSImage {
        let blockPt: CGFloat = 20
        let w = max(1, Int((bounds.width / blockPt).rounded(.up)))
        let h = max(1, Int((bounds.height / blockPt).rounded(.up)))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let data = ctx.data {
            let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for i in 0..<(w * h) {
                let shift = Int.random(in: -18...18)
                for c in 0..<3 {
                    let o = i * 4 + c
                    px[o] = UInt8(clamping: Int(px[o]) + shift + Int.random(in: -6...6))
                }
            }
        }
        guard let small = ctx.makeImage() else { return image }
        return NSImage(cgImage: small, size: bounds.size)
    }

    // MARK: Drawing

    func drawScene() {
        image.draw(in: bounds)
        guard let sel = selection else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).addClip()
        for a in annotations { draw(a) }
        if let c = current { draw(c) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func strokePath(_ p: NSBezierPath, _ color: NSColor, _ w: CGFloat) {
        p.lineWidth = w
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }

    /// Elle çizilen noktaları yumuşak eğriye çevirir (titrek çizgileri düzeltir).
    private func smoothPath(_ pts: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 {
            p.line(to: pts.last ?? first)
            return p
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.curve(to: mid, controlPoint: pts[i])
        }
        p.line(to: pts[pts.count - 1])
        return p
    }

    private func draw(_ a: Annotation) {
        let w = a.width
        switch a.tool {
        case .pen:
            let p = smoothPath(a.points)
            if a.filled && a.isClosedLoop {
                p.close()
                a.color.setFill()
                p.fill()
            }
            strokePath(p, a.color, w)
        case .marker:
            let p = smoothPath(a.points)
            p.lineWidth = w * 4 + 4
            p.lineCapStyle = .butt
            p.lineJoinStyle = .round
            a.color.withAlphaComponent(0.4).setStroke()
            p.stroke()
        case .line:
            let p = NSBezierPath()
            p.move(to: a.points[0]); p.line(to: a.points[1])
            strokePath(p, a.color, w)
        case .arrow:
            let s = a.points[0], e = a.points[1]
            let ang = atan2(e.y - s.y, e.x - s.x)
            let head = max(14, w * 4), spread = CGFloat.pi / 7
            let shaftEnd = CGPoint(x: e.x - cos(ang) * head * 0.7, y: e.y - sin(ang) * head * 0.7)
            let p = NSBezierPath()
            p.move(to: s); p.line(to: shaftEnd)
            strokePath(p, a.color, w)
            let tri = NSBezierPath()
            tri.move(to: e)
            tri.line(to: CGPoint(x: e.x - cos(ang - spread) * head, y: e.y - sin(ang - spread) * head))
            tri.line(to: CGPoint(x: e.x - cos(ang + spread) * head, y: e.y - sin(ang + spread) * head))
            tri.close()
            a.color.setFill()
            tri.fill()
        case .rect, .ellipse:
            let p = a.tool == .rect ? NSBezierPath(rect: a.rect) : NSBezierPath(ovalIn: a.rect)
            if a.filled { a.color.setFill(); p.fill() }
            strokePath(p, a.color, w)
        case .text:
            let attrs = Style.textAttributes(w, a.color)
            let str = a.text as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(at: CGPoint(x: a.points[0].x, y: a.points[0].y - size.height), withAttributes: attrs)
        case .step:
            let r = 10 + w * 1.5
            let c = a.points[0]
            let circle = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            a.color.setFill(); circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke(); circle.lineWidth = 1.5; circle.stroke()
            let fg: NSColor = (a.color == .white || a.color == .systemYellow) ? .black : .white
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold), .foregroundColor: fg]
            let s = "\(a.number)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
        case .blur:
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: a.rect).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            pixelated.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        case .select:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawScene()
        let dim = NSColor.black.withAlphaComponent(0.45)
        guard let sel = selection else {
            dim.setFill()
            NSBezierPath(rect: bounds).fill()
            drawHint(center: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: sel))
        shade.windingRule = .evenOdd
        dim.setFill()
        shade.fill()

        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.setLineDash([5, 4], count: 2, phase: 0)
        border.stroke()

        if tool == .select {
            for h in Handle.allCases {
                let p = h.point(in: sel)
                let r = NSBezierPath(rect: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                NSColor.white.setFill(); r.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke(); r.lineWidth = 1; r.stroke()
            }
        }

        let scale = window?.backingScaleFactor ?? 2
        let label = "\(Int((sel.width * scale).rounded())) × \(Int((sel.height * scale).rounded()))"
        var y = sel.maxY + 16
        if y > bounds.height - 12 { y = sel.maxY - 16 }
        drawPill(label, center: CGPoint(x: sel.minX, y: y), anchorLeft: true)
    }

    /// Seçim yapılmadan önce ortada görünen, büyük ve okunaklı ipucu kartı.
    private func drawHint(center: CGPoint) {
        let title = "Tıklayın ve seçin" as NSString
        let keys: NSString? = allowFullScreen ? "⌘A: tam ekran" : nil
        let tAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let kAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        let ts = title.size(withAttributes: tAttrs)
        let ks = keys?.size(withAttributes: kAttrs) ?? .zero
        let gap: CGFloat = keys == nil ? 0 : 6, padX: CGFloat = 26, padY: CGFloat = 14
        let w = max(ts.width, ks.width) + padX * 2
        let h = ts.height + gap + ks.height + padY * 2
        let r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let card = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.85).setFill()
        card.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        card.lineWidth = 1
        card.stroke()
        title.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.maxY - padY - ts.height), withAttributes: tAttrs)
        keys?.draw(at: CGPoint(x: r.midX - ks.width / 2, y: r.minY + padY), withAttributes: kAttrs)
    }

    private func drawPill(_ text: String, center: CGPoint, anchorLeft: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        var r = CGRect(x: center.x - sz.width / 2 - 8, y: center.y - sz.height / 2 - 4, width: sz.width + 16, height: sz.height + 8)
        if anchorLeft { r.origin.x = center.x }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        s.draw(at: CGPoint(x: r.minX + 8, y: r.minY + 4), withAttributes: attrs)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if tool == .select, let sel = selection, sel != bounds { addCursorRect(sel, cursor: .openHand) }
    }

    // MARK: Mouse

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func handle(at p: CGPoint, in sel: CGRect) -> Handle? {
        Handle.allCases.first { h in
            let hp = h.point(in: sel)
            return abs(hp.x - p.x) <= 7 && abs(hp.y - p.y) <= 7
        }
    }

    private func nextStep() -> Int {
        (annotations.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1
    }

    override func mouseDown(with e: NSEvent) {
        commitText()
        let p = clamp(convert(e.locationInWindow, from: nil))
        guard let sel = selection else {
            controller?.clearSelections(except: self)
            drag = .select(p)
            return
        }
        if e.clickCount == 2, tool == .select, sel.contains(p) {
            copyAction(nil)
            return
        }
        switch tool {
        case .select:
            if let h = handle(at: p, in: sel) { drag = .resize(h, sel) }
            else if sel.contains(p) && sel != bounds { drag = .move(p, sel); NSCursor.closedHand.set() }
            else { controller?.clearSelections(except: self); drag = .select(p) }
        case .text:
            beginText(at: p)
        case .step:
            annotations.append(Annotation(tool: .step, points: [p], color: color, width: lineWidth, number: nextStep()))
            needsDisplay = true
        case .pen, .marker:
            current = Annotation(tool: tool, points: [p], color: color, width: lineWidth, filled: fillShapes)
            drag = .draw
        default:
            current = Annotation(tool: tool, points: [p, p], color: color, width: lineWidth, filled: fillShapes)
            drag = .draw
        }
    }

    override func mouseDragged(with e: NSEvent) {
        var p = clamp(convert(e.locationInWindow, from: nil))
        switch drag {
        case .select(let s):
            previousSelection = nil
            var r = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(s.x - p.x), height: abs(s.y - p.y))
            if e.modifierFlags.contains(.shift) {
                let d = max(r.width, r.height)
                r = CGRect(x: p.x < s.x ? s.x - d : s.x, y: p.y < s.y ? s.y - d : s.y, width: d, height: d)
            }
            selection = r
        case .move(let s, let orig):
            previousSelection = nil
            var r = orig.offsetBy(dx: p.x - s.x, dy: p.y - s.y)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            selection = r
        case .resize(let h, let o):
            previousSelection = nil
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if [.tl, .bl, .l].contains(h) { minX = p.x }
            if [.tr, .br, .r].contains(h) { maxX = p.x }
            if [.tl, .t, .tr].contains(h) { maxY = p.y }
            if [.bl, .b, .br].contains(h) { minY = p.y }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        case .draw:
            guard var c = current else { break }
            if c.tool == .marker && e.modifierFlags.contains(.shift) {
                // Shift: fosforlu kalem tam yatay düz çizgi
                c.points = [c.points[0], CGPoint(x: p.x, y: c.points[0].y)]
            } else if c.tool == .pen || c.tool == .marker {
                if let last = c.points.last, hypot(last.x - p.x, last.y - p.y) < 1.5 { break }
                c.points.append(p)
            } else {
                let s = c.points[0]
                if e.modifierFlags.contains(.shift) {
                    let dx = p.x - s.x, dy = p.y - s.y
                    if c.tool == .line || c.tool == .arrow {
                        let step = CGFloat.pi / 4
                        let ang = (atan2(dy, dx) / step).rounded() * step
                        let len = hypot(dx, dy)
                        p = CGPoint(x: s.x + cos(ang) * len, y: s.y + sin(ang) * len)
                    } else {
                        let d = max(abs(dx), abs(dy))
                        p = CGPoint(x: s.x + (dx < 0 ? -d : d), y: s.y + (dy < 0 ? -d : d))
                    }
                }
                c.points[1] = p
            }
            current = c
        case .none:
            break
        }
        if case .draw = drag {} else { updateToolbar() }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case .select:
            if let s = selection, s.width < 3 || s.height < 3 { selection = nil }
        case .draw:
            if var c = current {
                if c.tool == .marker { straighten(&c) }
                if c.isMeaningful { annotations.append(c) }
            }
            current = nil
        default:
            break
        }
        drag = .none
        updateToolbar()
        needsDisplay = true
    }

    /// Fosforlu kalemle neredeyse düz çizilen çizgiyi tamamen düzeltir (metnin altını çizerken).
    private func straighten(_ c: inout Annotation) {
        guard c.points.count > 2, let s = c.points.first, let e = c.points.last else { return }
        let len = hypot(e.x - s.x, e.y - s.y)
        guard len > 30 else { return }
        let dx: CGFloat = e.x - s.x, dy: CGFloat = e.y - s.y
        var maxDev: CGFloat = 0
        for p in c.points {
            let cross: CGFloat = dx * (s.y - p.y) - (s.x - p.x) * dy
            maxDev = max(maxDev, abs(cross) / len)
        }
        if maxDev < max(6, len * 0.05) { c.points = [s, e] }
    }

    // MARK: Toolbar / state

    func toggleFill() {
        commitText()
        fillShapes.toggle()
        // Hemen etkisi görünsün: son çizilen şekli de doldur / boşalt
        if let i = annotations.indices.last {
            let a = annotations[i]
            if a.tool == .rect || a.tool == .ellipse || (a.tool == .pen && a.isClosedLoop) {
                annotations[i].filled = fillShapes
            }
        }
        // Dolgu yalnızca dikdörtgen, elips ve kalemde anlamlı
        if fillShapes && ![.rect, .ellipse, .pen].contains(tool) { tool = .rect }
        updateToolbar()
        needsDisplay = true
    }

    /// Araç çubuğundaki "Tam ekran" düğmesi: alan ↔ tam ekran arasında geçiş yapar.
    /// Tam ekrandayken tekrar basınca, elle yeniden seçmeye gerek kalmadan önceki alana döner.
    func expandToFullScreen() {
        commitText()
        if isFullScreenSelection {
            // Önceki alan varsa ona dön; yoksa yeniden alan seçme moduna geç
            selection = previousSelection
            previousSelection = nil
            tool = .select
            updateToolbar()
            needsDisplay = true
        } else {
            selectWholeScreen()
        }
    }

    func updateToolbar() {
        window?.invalidateCursorRects(for: self)
        guard let sel = selection else { toolbar?.isHidden = true; return }
        if toolbar == nil {
            let t = ToolbarView(overlay: self)
            addSubview(t)
            toolbar = t
        }
        guard let t = toolbar else { return }
        t.isHidden = false
        t.refresh()
        let size = t.frame.size
        var x = sel.maxX - size.width
        var y = sel.minY - size.height - 8
        if y < 4 { y = sel.maxY + 34 }
        if y + size.height > bounds.height - 4 { y = sel.minY + 8 }
        x = min(max(4, x), bounds.width - size.width - 4)
        t.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func setTool(_ t: Tool) {
        commitText()
        tool = t
        updateToolbar()
        needsDisplay = true
    }

    func setColor(_ c: NSColor) {
        color = c
        textField?.textColor = c
        toolbar?.refresh()
    }

    func setWidth(_ w: CGFloat) {
        lineWidth = w
        toolbar?.refresh()
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        let f = NSTextField(string: "")
        f.font = Style.textFont(lineWidth)
        f.textColor = color
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        f.focusRingType = .none
        f.placeholderString = "Metin yazın, Enter"
        f.delegate = self
        f.sizeToFit()
        let h = f.frame.height
        f.frame = CGRect(x: p.x, y: p.y - h, width: 180, height: h)
        textWidth = lineWidth
        addSubview(f)
        textField = f
        window?.makeFirstResponder(f)
    }

    func commitText() {
        guard let f = textField else { return }
        textField = nil
        let s = f.stringValue
        if !s.isEmpty {
            annotations.append(Annotation(tool: .text, points: [CGPoint(x: f.frame.minX + 2, y: f.frame.maxY)],
                                          color: f.textColor ?? color, width: textWidth, text: s))
        }
        f.delegate = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = textField else { return }
        let w = max(180, f.attributedStringValue.size().width + 24)
        f.setFrameSize(NSSize(width: w, height: f.frame.height))
    }

    func controlTextDidEndEditing(_ n: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            textField?.stringValue = ""
            commitText()
            return true
        }
        return false
    }

    // MARK: Keyboard & actions

    /// 1–9 ve 0 tuşları (üst sıra ve sayı tuş takımı) → araç çubuğundaki sıraya göre araç.
    static let numberTools: [Int: Tool] = {
        let top = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                   kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]
        let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                   kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_Keypad0]
        var m: [Int: Tool] = [:]
        for (i, t) in Tool.allCases.enumerated() where i < 10 { m[top[i]] = t; m[pad[i]] = t }
        return m
    }()

    override func keyDown(with e: NSEvent) {
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.modifierFlags.contains(.command) {
            switch chars {
            case "z": undoAction(nil)
            case "c": copyAction(nil)
            case "s": saveAction(nil)
            case "a": selectAllAction(nil)
            default: super.keyDown(with: e)
            }
            return
        }
        switch Int(e.keyCode) {
        case kVK_Escape:
            if case .draw = drag { current = nil; drag = .none; needsDisplay = true; return }
            controller?.finish(hideApp: true)
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            copyAction(nil)
            return
        case kVK_Delete:
            undoAction(nil)
            return
        case kVK_Space:
            selectAllAction(nil)
            return
        default: break
        }
        if selection != nil, chars == "f" {
            toggleFill()
        } else if selection != nil, let t = Tool.allCases.first(where: { $0.key == chars }) {
            setTool(t)
        } else if selection != nil, let t = Self.numberTools[Int(e.keyCode)] {
            setTool(t) // rakam tuşları araç seçer (renk değil)
        }
    }

    @objc(undo:) func undoAction(_ sender: Any?) {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    @objc(selectAll:) func selectAllAction(_ sender: Any?) {
        guard allowFullScreen else { NSSound.beep(); return }
        // Birden fazla ekranda: imlecin olduğu ekranın tamamını seç
        if let other = controller?.overlayUnderMouse(), other !== self {
            other.selectWholeScreen()
        } else {
            selectWholeScreen()
        }
    }

    func selectWholeScreen() {
        controller?.clearSelections(except: self)
        if let s = selection, s != bounds { previousSelection = s }
        selection = bounds
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        updateToolbar()
        needsDisplay = true
    }

    /// Başka ekranda yeni seçim başlayınca bu ekranın seçimini temizler.
    func clearSelection() {
        commitText()
        guard selection != nil || current != nil else { return }
        selection = nil
        current = nil
        annotations.removeAll()
        updateToolbar()
        needsDisplay = true
    }

    @objc(copy:) func copyAction(_ sender: Any?) {
        commitText()
        guard let (png, tiff) = render() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff { pb.setData(tiff, forType: .tiff) }
        NSSound(named: "Pop")?.play()
        controller?.finish(hideApp: true)
    }

    @objc(saveImage:) func saveAction(_ sender: Any?) {
        commitText()
        guard let (png, _) = render() else { return }
        controller?.finish(hideApp: false)
        Saver.save(png)
    }

    /// Seçili alanı (çizimlerle birlikte) tam çözünürlükte PNG'ye dönüştürür.
    func render() -> (Data, Data?)? {
        guard let sel = selection?.integral, sel.width >= 1, sel.height >= 1 else { NSSound.beep(); return nil }
        let scale = CGFloat(cgImage.width) / bounds.width
        let pw = Int((sel.width * scale).rounded()), ph = Int((sel.height * scale).rounded())
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        drawScene()
        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = sel.size
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, rep.tiffRepresentation)
    }
}

// MARK: - Toolbar

final class DotView: NSView {
    let fill: NSColor
    let diameter: CGFloat
    let onClick: () -> Void
    var selected = false { didSet { needsDisplay = true } }

    init(fill: NSColor, diameter: CGFloat, tip: String, onClick: @escaping () -> Void) {
        self.fill = fill; self.diameter = diameter; self.onClick = onClick
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 28))
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let r = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        let p = NSBezierPath(ovalIn: r)
        fill.setFill(); p.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke(); p.lineWidth = 1; p.stroke()
        if selected {
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 1.5
            NSColor.white.setStroke(); ring.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onClick() }
}

final class ToolbarView: NSView {
    weak var overlay: OverlayView?
    private var toolButtons: [Tool: NSButton] = [:]
    private var colorDots: [DotView] = []
    private var widthDots: [DotView] = []
    private var fillButton: NSButton!
    private var fullButton: NSButton!

    init(overlay: OverlayView) {
        self.overlay = overlay
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        fullButton = iconButton("arrow.up.left.and.arrow.down.right",
                                tip: "Tam ekran — seçimi bu ekranın tamamına genişlet",
                                action: #selector(fullScreenTapped))
        stack.addArrangedSubview(fullButton)
        stack.addArrangedSubview(separator())
        for t in Tool.allCases {
            let b = iconButton(t.symbol, tip: t.title, action: #selector(toolTapped(_:)))
            b.tag = t.rawValue
            toolButtons[t] = b
            stack.addArrangedSubview(b)
        }
        fillButton = iconButton("circle.lefthalf.filled",
                                tip: "İçi dolu (F) — dikdörtgen, elips ve başı-sonu birleşen kalem çizimi",
                                action: #selector(fillTapped))
        stack.addArrangedSubview(fillButton)
        stack.addArrangedSubview(separator())
        for (i, c) in Style.colors.enumerated() {
            let d = DotView(fill: c, diameter: 14, tip: "Renk") { [weak overlay] in overlay?.setColor(c) }
            colorDots.append(d)
            stack.addArrangedSubview(d)
        }
        stack.addArrangedSubview(separator())
        for (w, name) in zip(Style.widths, ["İnce", "Orta", "Kalın"]) {
            let d = DotView(fill: .white, diameter: w + 3, tip: "Kalınlık: \(name)") { [weak overlay] in overlay?.setWidth(w) }
            widthDots.append(d)
            stack.addArrangedSubview(d)
        }
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(iconButton("arrow.uturn.backward", tip: "Geri al (⌘Z)", action: #selector(undo)))
        stack.addArrangedSubview(iconButton("square.and.arrow.down", tip: "Kaydet (⌘S)", action: #selector(save)))
        stack.addArrangedSubview(iconButton("doc.on.doc", tip: "Panoya kopyala (⌘C / Enter / çift tık)", action: #selector(copyImg)))
        stack.addArrangedSubview(iconButton("xmark", tip: "Kapat (Esc)", action: #selector(close)))

        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        addSubview(stack)
        setFrameSize(size)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        let b = img.map { NSButton(image: $0, target: self, action: action) } ?? NSButton(title: "•", target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return v
    }

    func refresh() {
        guard let o = overlay else { return }
        for (t, b) in toolButtons {
            b.layer?.backgroundColor = (t == o.tool ? NSColor.controlAccentColor : .clear).cgColor
        }
        for (d, c) in zip(colorDots, Style.colors) { d.selected = (c == o.color) }
        for (d, w) in zip(widthDots, Style.widths) { d.selected = (w == o.lineWidth) }
        fillButton.layer?.backgroundColor = (o.fillShapes ? NSColor(white: 1, alpha: 0.28) : .clear).cgColor
        // Dolgu açıkken dikdörtgen ve elips simgeleri dolu görünsün
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        // Tam ekran düğmesi: tam ekrandaysa "önceki alana dön" simgesi
        let back = o.isFullScreenSelection
        fullButton.image = NSImage(systemSymbolName: back ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        fullButton.toolTip = !back ? "Tam ekran — seçimi bu ekranın tamamına genişlet"
            : (o.previousSelection != nil ? "Önceki alana dön" : "Yeniden alan seç")
        toolButtons[.rect]?.image = NSImage(systemSymbolName: o.fillShapes ? "rectangle.fill" : "rectangle",
                                            accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        toolButtons[.ellipse]?.image = NSImage(systemSymbolName: o.fillShapes ? "circle.fill" : "circle",
                                               accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    @objc private func fillTapped() { overlay?.toggleFill() }
    @objc private func fullScreenTapped() { overlay?.expandToFullScreen() }

    override func mouseDown(with event: NSEvent) {} // arka plana tıklama alttaki seçime geçmesin
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    @objc private func toolTapped(_ b: NSButton) { if let t = Tool(rawValue: b.tag) { overlay?.setTool(t) } }
    @objc private func undo() { overlay?.undoAction(nil) }
    @objc private func save() { overlay?.saveAction(nil) }
    @objc private func copyImg() { overlay?.copyAction(nil) }
    @objc private func close() { overlay?.controller?.finish(hideApp: true) }
}

// MARK: - Saving

enum Saver {
    static let dirKey = "saveDirectory"

    static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "HexShot \(f.string(from: Date())).png"
    }

    static func save(_ png: Data) {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName()
        panel.canCreateDirectories = true
        if let path = UserDefaults.standard.string(forKey: dirKey) {
            panel.directoryURL = URL(fileURLWithPath: path)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try png.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: dirKey)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        NSApp.hide(nil)
    }
}

// MARK: - Capture

@MainActor
final class CaptureController {
    private var windows: [OverlayWindow] = []
    private var busy = false

    func start(fullScreen: Bool = false, allowFullScreen: Bool = true) {
        guard windows.isEmpty, !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "Ekran kaydı izni gerekiyor"
            a.informativeText = "Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Ses Kaydı bölümünden “HexShot” uygulamasını açın, ardından uygulamayı yeniden başlatın."
            a.addButton(withTitle: "Ayarları Aç")
            a.addButton(withTitle: "Vazgeç")
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var shots: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
                    cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
                    cfg.showsCursor = false
                    cfg.captureResolution = .best
                    cfg.queueDepth = 1 // tek kare yeter; varsayılan 3 kare RAM'de ~3 ekran görüntüsü kadar yer tutuyordu
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    shots.append((screen, img))
                }
                present(shots, fullScreen: fullScreen, allowFullScreen: allowFullScreen)
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        }
    }

    private func present(_ shots: [(NSScreen, CGImage)], fullScreen: Bool, allowFullScreen: Bool) {
        let mouse = NSEvent.mouseLocation
        var keyWindow: OverlayWindow?
        for (screen, img) in shots {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.setFrame(screen.frame, display: false)
            let v = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), cgImage: img)
            v.controller = self
            v.allowFullScreen = allowFullScreen || fullScreen
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
            if screen.frame.contains(mouse) { keyWindow = w }
        }
        NSApp.activate()
        if let k = keyWindow ?? windows.first {
            k.makeKeyAndOrderFront(nil)
            k.makeFirstResponder(k.contentView)
            // Tam ekran modu: imlecin bulunduğu ekran hazır seçili gelir (Enter = kopyala)
            if fullScreen { (k.contentView as? OverlayView)?.selectWholeScreen() }
        }
    }

    var overlays: [OverlayView] { windows.compactMap { $0.contentView as? OverlayView } }

    func overlayUnderMouse() -> OverlayView? {
        let m = NSEvent.mouseLocation
        return windows.first { $0.frame.contains(m) }?.contentView as? OverlayView
    }

    func clearSelections(except keep: OverlayView) {
        for v in overlays where v !== keep { v.clearSelection() }
    }

    func finish(hideApp: Bool) {
        let ws = windows
        windows = []
        // Pencereleri gerçekten kapatıp içeriği bırak ki ekran görüntüsü RAM'de kalmasın.
        for w in ws {
            w.orderOut(nil)
            w.contentView = nil
            w.close()
        }
        if hideApp { NSApp.hide(nil) }
        // Serbest kalan büyük bellek bloklarını işletim sistemine hemen geri ver
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = malloc_zone_pressure_relief(nil, 0) }
    }
}

// MARK: - Shortcuts

struct Shortcut: Equatable {
    var keyCode: UInt32
    var mods: UInt32 // Carbon modifier mask
    var key: String

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var dict: [String: Any] { ["k": Int(keyCode), "m": Int(mods), "l": key] }

    init(keyCode: UInt32, mods: UInt32, key: String) {
        self.keyCode = keyCode; self.mods = mods; self.key = key
    }

    init?(dict: Any?) {
        guard let d = dict as? [String: Any], let k = d["k"] as? Int, let m = d["m"] as? Int, let l = d["l"] as? String
        else { return nil }
        self.init(keyCode: UInt32(k), mods: UInt32(m), key: l)
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    static func keyName(_ e: NSEvent) -> String {
        let code = Int(e.keyCode)
        if let f = functionKeys[code] { return f }
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (e.characters(byApplyingModifiers: []) ?? "?").uppercased()
        }
    }
}

enum ShortcutAction: UInt32, CaseIterable {
    case region = 1, full = 2, choose = 3

    var defaultsKey: String {
        switch self {
        case .region: "hotkey.region"
        case .full: "hotkey.full"
        case .choose: "hotkey.choose"
        }
    }
    var title: String {
        switch self {
        case .region: "Alan seç"
        case .full: "Tam ekran"
        case .choose: "Seçerek çek"
        }
    }
    var fallback: Shortcut {
        let m = UInt32(cmdKey | shiftKey)
        switch self {
        case .region: return Shortcut(keyCode: UInt32(kVK_ANSI_1), mods: m, key: "1")
        case .full: return Shortcut(keyCode: UInt32(kVK_ANSI_2), mods: m, key: "2")
        case .choose: return Shortcut(keyCode: UInt32(kVK_ANSI_0), mods: m, key: "0")
        }
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    func shortcut(for a: ShortcutAction) -> Shortcut? {
        let v = UserDefaults.standard.object(forKey: a.defaultsKey)
        if v == nil { return a.fallback }
        return Shortcut(dict: v) // "none" saklanmışsa nil → kısayol yok
    }

    func set(_ s: Shortcut?, for a: ShortcutAction) {
        UserDefaults.standard.set(s?.dict ?? "none", forKey: a.defaultsKey)
        // Aynı kısayol başka bir işlemdeyse oradan kaldır
        if let s {
            for other in ShortcutAction.allCases where other != a && shortcut(for: other) == s {
                UserDefaults.standard.set("none", forKey: other.defaultsKey)
            }
        }
    }

    func registerAll() {
        unregisterAll()
        installHandler()
        for a in ShortcutAction.allCases {
            guard let s = shortcut(for: a) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4845_5853), id: a.rawValue) // 'HEXS'
            if RegisterEventHotKey(s.keyCode, s.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in (NSApp.delegate as? AppDelegate)?.handleHotKey(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Tıklayıp yeni kısayola basılarak ayarlanan kutu.
final class ShortcutField: NSView {
    let action: ShortcutAction
    var onChange: (() -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    init(action: ShortcutAction) {
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: 170, height: 26))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 26) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        p.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        p.lineWidth = 1
        p.stroke()
        let text = recording ? "Kısayola basın…" : (HotKeyCenter.shared.shortcut(for: action)?.display ?? "Yok")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func becomeFirstResponder() -> Bool {
        recording = true
        HotKeyCenter.shared.unregisterAll() // kayıt sırasında mevcut kısayollar tetiklenmesin
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        HotKeyCenter.shared.registerAll()
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with e: NSEvent) {
        guard recording else { super.keyDown(with: e); return }
        let code = Int(e.keyCode)
        switch code {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
            return
        case kVK_Delete, kVK_ForwardDelete:
            HotKeyCenter.shared.set(nil, for: action)
        default:
            let mods = Shortcut.carbonMods(e.modifierFlags)
            let needsModifier = Shortcut.functionKeys[code] == nil
            if needsModifier && mods & UInt32(cmdKey | controlKey | optionKey) == 0 {
                NSSound.beep() // ⌘, ⌃ veya ⌥ olmadan tek tuş kabul edilmez (F tuşları hariç)
                return
            }
            HotKeyCenter.shared.set(Shortcut(keyCode: UInt32(code), mods: mods, key: Shortcut.keyName(e)), for: action)
        }
        window?.makeFirstResponder(nil)
        onChange?()
    }
}

// MARK: - Settings window

@MainActor
final class SettingsController: NSObject {
    private var window: NSWindow?
    private var fields: [ShortcutField] = []
    private var loginCheck: NSButton!
    private var screenButton: NSButton!
    var onChange: (() -> Void)?

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    /// İzin ve giriş durumunu günceller (Sistem Ayarları'ndan dönünce de çağrılır).
    private func refresh() {
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let ok = Permissions.screenRecording
        screenButton.title = ok ? "✓ Verildi" : "İzin ver…"
        screenButton.isEnabled = !ok
        fields.forEach { $0.needsDisplay = true }
    }

    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.identifier = NSUserInterfaceItemIdentifier("header")
        return l
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 10
        g.columnSpacing = 10
        g.rowAlignment = .firstBaseline
        g.column(at: 0).width = 150
        return g
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "HexShot Ayarları"
        w.isReleasedWhenClosed = false

        let region = ShortcutField(action: .region)
        let full = ShortcutField(action: .full)
        let choose = ShortcutField(action: .choose)
        fields = [region, full, choose]
        for f in fields {
            f.onChange = { [weak self] in
                self?.fields.forEach { $0.needsDisplay = true }
                self?.onChange?()
            }
        }
        loginCheck = NSButton(checkboxWithTitle: "Mac açılınca otomatik başlat", target: self, action: #selector(toggleLogin))
        screenButton = NSButton(title: "İzin ver…", target: self, action: #selector(openScreen))
        screenButton.bezelStyle = .rounded

        let note = NSTextField(wrappingLabelWithString:
            "Kısayolu değiştirmek için kutuya tıklayıp yeni tuş kombinasyonuna basın. ⌫ kısayolu kaldırır, Esc vazgeçer.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let permNote = NSTextField(wrappingLabelWithString:
            "HexShot yalnızca Ekran Kaydı iznine ihtiyaç duyar. İzni verdikten sonra uygulamayı kapatıp yeniden açın.")
        permNote.font = .systemFont(ofSize: 11)
        permNote.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            header("Genel"),
            grid([[label("Başlangıç:"), loginCheck]]),
            header("İzinler"),
            grid([[label("Ekran kaydı:"), screenButton]]),
            permNote,
            header("Kısayollar"),
            grid([
                [label("Alan seç:"), region],
                [label("Tam ekran:"), full],
                [label("Seçerek çek:"), choose],
            ]),
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Bölüm başlıklarından önce daha fazla boşluk
        let views = stack.arrangedSubviews
        for (i, v) in views.enumerated() where i > 0 && v.identifier?.rawValue == "header" {
            stack.setCustomSpacing(22, after: views[i - 1])
        }
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 380).isActive = true
        permNote.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        w.center()
        window = w
        // Sistem Ayarları'ndan geri dönünce izin durumunu yenile
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @objc private func toggleLogin() {
        LoginItem.toggle()
        refresh()
    }

    @objc private func openScreen() { Permissions.openScreenRecording() }
}

enum LoginItem {
    static let pathKey = "loginItemPath"

    static let wantedKey = "loginItemWanted"

    /// Kullanıcı "Girişte başlat"ı açtı mı? (Eski sürümlerde açıldıysa yol kaydı bunu gösterir.)
    static var wanted: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: wantedKey) != nil { return d.bool(forKey: wantedKey) }
        return d.string(forKey: pathKey) != nil
    }

    /// Uygulama taşındıysa, güncellendiyse veya yeniden kurulduysa giriş öğesini
    /// kullanıcının tercihine göre yeniden kaydeder (yeniden kurulum onu kapatabiliyor).
    @MainActor static func refreshLocationIfNeeded() {
        guard wanted else { return }
        let here = Bundle.main.bundlePath
        let svc = SMAppService.mainApp
        if svc.status == .enabled && UserDefaults.standard.string(forKey: pathKey) == here { return }
        if svc.status == .enabled { try? svc.unregister() }
        if (try? svc.register()) != nil {
            UserDefaults.standard.set(here, forKey: pathKey)
        }
    }

    @MainActor static func toggle() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: wantedKey)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: wantedKey)
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: pathKey)
            }
        } catch {
            // Olmazsa Giriş Öğeleri ayarlarını aç, elle eklenebilsin.
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecording() {
        _ = CGRequestScreenCaptureAccess() // uygulamayı listeye ekler
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Self test (yalnızca --selftest ile çalışır: RAM / CPU / disk ölçümü)

@MainActor
enum SelfTest {
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// (toplam işlemci süresi ms, diske yazılan bayt)
    static func usage() -> (cpuMs: Double, written: UInt64) {
        var ri = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return (-1, 0) }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ns = Double(ri.ri_user_time + ri.ri_system_time) * Double(tb.numer) / Double(tb.denom)
        return (ns / 1_000_000, ri.ri_diskio_byteswritten)
    }

    static func log(_ s: String) { print(s); fflush(stdout) }

    static func run(_ capture: CaptureController) {
        guard CGPreflightScreenCaptureAccess() else { log("İZİN YOK: ekran kaydı izni verilmemiş"); exit(1) }
        let u0 = usage()
        log(String(format: "Ekran sayısı: %d", NSScreen.screens.count))
        log(String(format: "Boşta RAM: %.1f MB", footprint()))
        // Boşta işlemci: 3 sn bekle, harcanan süreyi ölç
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let u1 = usage()
            log(String(format: "Boşta işlemci: %.2f ms / 3 sn  (≈ %%%.3f)", u1.cpuMs - u0.cpuMs, (u1.cpuMs - u0.cpuMs) / 30))
            let tCap = Date()
            capture.start(fullScreen: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let v = capture.overlays.first(where: { $0.selection != nil }) ?? capture.overlays.first else {
                    log("Ekran açılamadı"); exit(1)
                }
                _ = tCap
                log(String(format: "Ekran açıkken RAM: %.1f MB", footprint()))
                // Çizim hızı: tüm ekranı 30 kez yeniden çiz
                var t = Date()
                for _ in 0..<30 { v.display() }
                log(String(format: "Bir kare çizim süresi: %.1f ms", Date().timeIntervalSince(t) * 1000 / 30))
                // Bulanıklaştırma + çizimler (--noblur ile atlanır)
                let b = v.bounds
                if !CommandLine.arguments.contains("--noblur") { v.annotations.append(Annotation(tool: .blur, points: [CGPoint(x: b.midX - 200, y: b.midY - 100), CGPoint(x: b.midX + 200, y: b.midY + 100)], color: .red, width: 4)) }
                v.annotations.append(Annotation(tool: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 300)], color: .red, width: 4))
                t = Date()
                v.display()
                log(String(format: "Bulanıklaştırma ilk uygulama: %.0f ms", Date().timeIntervalSince(t) * 1000))
                t = Date()
                for _ in 0..<30 { v.display() }
                log(String(format: "Bulanıklık varken kare süresi: %.1f ms", Date().timeIntervalSince(t) * 1000 / 30))
                log(String(format: "Bulanıklık sonrası RAM: %.1f MB", footprint()))
                t = Date()
                let png = v.render()
                log(String(format: "PNG oluşturma: %.0f ms, %.1f MB (bellekte, diske yazılmadı)",
                           Date().timeIntervalSince(t) * 1000, Double(png?.0.count ?? 0) / 1_048_576))
                capture.finish(hideApp: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let u2 = usage()
                    log(String(format: "Kapandıktan sonra RAM: %.1f MB", footprint()))
                    log(String(format: "Tüm test boyunca işlemci: %.0f ms", u2.cpuMs - u0.cpuMs))
                    log("Diske yazılan: \(u2.written - u0.written) bayt")
                    exit(0)
                }
            }
        }
    }
}

// MARK: - UI test (yalnızca --uitest ile: sahte fare/klavye olaylarıyla tüm akışları dener)

@MainActor
enum UITest {
    static var fails = 0
    static func log(_ s: String) { print(s); fflush(stdout) }
    static func check(_ name: String, _ ok: Bool) {
        log((ok ? "✓ " : "✗ ") + name)
        if !ok { fails += 1 }
    }
    static func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    static func mouse(_ v: OverlayView, _ type: NSEvent.EventType, _ p: CGPoint, mods: NSEvent.ModifierFlags = []) {
        guard let w = v.window, let e = NSEvent.mouseEvent(
            with: type, location: v.convert(p, to: nil), modifierFlags: mods,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: v.mouseDown(with: e)
        case .leftMouseDragged: v.mouseDragged(with: e)
        default: v.mouseUp(with: e)
        }
    }

    static func drag(_ v: OverlayView, _ a: CGPoint, _ b: CGPoint) {
        mouse(v, .leftMouseDown, a)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            mouse(v, .leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        mouse(v, .leftMouseUp, b)
    }

    static func path(_ v: OverlayView, _ pts: [CGPoint]) {
        mouse(v, .leftMouseDown, pts[0])
        for p in pts.dropFirst() { mouse(v, .leftMouseDragged, p) }
        mouse(v, .leftMouseUp, pts.last!)
    }

    static func click(_ v: OverlayView, _ p: CGPoint) {
        mouse(v, .leftMouseDown, p); mouse(v, .leftMouseUp, p)
    }

    static func key(_ v: OverlayView, _ code: Int, _ chars: String, mods: NSEvent.ModifierFlags = []) {
        guard let w = v.window, let e = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)) else { return }
        v.keyDown(with: e)
    }

    static func waitOverlay(_ c: CaptureController, tries: Int = 30, _ f: @escaping (OverlayView) -> Void) {
        if let v = c.overlays.first { f(v); return }
        guard tries > 0 else { check("Çekim ekranı açıldı", false); finish(); return }
        after(0.2) { waitOverlay(c, tries: tries - 1, f) }
    }

    static func toolbarVisible(_ v: OverlayView) -> Bool { v.subviews.contains { $0 is ToolbarView && !$0.isHidden } }

    static func run(_ c: CaptureController) {
        guard CGPreflightScreenCaptureAccess() else { log("İZİN YOK"); exit(2) }
        log("— 1) Alan seç modu —")
        c.start(allowFullScreen: false)
        waitOverlay(c) { v in
            check("Başta seçim yok", v.selection == nil)
            key(v, kVK_ANSI_A, "a", mods: .command)
            check("Alan seç modunda ⌘A tam ekran yapmıyor", v.selection == nil)
            key(v, kVK_Space, " ")
            check("Alan seç modunda Boşluk tam ekran yapmıyor", v.selection == nil)
            click(v, CGPoint(x: 50, y: 50))
            check("Tek tıklama boş seçim oluşturmuyor", v.selection == nil)

            drag(v, CGPoint(x: 100, y: 100), CGPoint(x: 600, y: 500))
            check("Sürükleyerek alan seçimi", v.selection == CGRect(x: 100, y: 100, width: 500, height: 400))
            check("Araç çubuğu göründü", toolbarVisible(v))

            let keys: [(Int, String, Tool)] = [
                (kVK_ANSI_2, "2", .pen), (kVK_ANSI_3, "3", .line), (kVK_ANSI_4, "4", .arrow),
                (kVK_ANSI_5, "5", .rect), (kVK_ANSI_6, "6", .ellipse), (kVK_ANSI_7, "7", .marker),
                (kVK_ANSI_8, "8", .text), (kVK_ANSI_9, "9", .blur), (kVK_ANSI_0, "0", .step),
                (kVK_ANSI_Keypad4, "4", .arrow), (kVK_ANSI_1, "1", .select),
            ]
            for (code, ch, t) in keys {
                key(v, code, ch)
                check("Tuş \(ch) → \(t)", v.tool == t)
            }
            check("Rakam tuşları rengi değiştirmedi", v.color == .systemRed)

            key(v, kVK_ANSI_4, "4")
            drag(v, CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 300))
            check("Ok çizildi", v.annotations.last?.tool == .arrow)

            key(v, kVK_ANSI_5, "5")
            key(v, kVK_ANSI_F, "f")
            check("F: içi dolu açıldı", v.fillShapes)
            drag(v, CGPoint(x: 200, y: 200), CGPoint(x: 350, y: 320))
            check("Dolu dikdörtgen çizildi", v.annotations.last?.tool == .rect && v.annotations.last?.filled == true)
            key(v, kVK_ANSI_F, "f")
            check("F tekrar: son dikdörtgen boşaldı", v.fillShapes == false && v.annotations.last?.filled == false)
            key(v, kVK_ANSI_4, "4")
            key(v, kVK_ANSI_F, "f")
            check("Doldurulamayan araçta F → dikdörtgene geçti", v.tool == .rect)
            key(v, kVK_ANSI_F, "f")

            key(v, kVK_ANSI_2, "2")
            key(v, kVK_ANSI_F, "f")
            var circle: [CGPoint] = []
            for i in 0...36 {
                let a = CGFloat(i) / 36 * 2 * .pi
                circle.append(CGPoint(x: 450 + cos(a) * 60, y: 350 + sin(a) * 60))
            }
            path(v, circle)
            check("Kalem: kapalı şekil içi dolu", v.annotations.last?.tool == .pen
                  && v.annotations.last?.isClosedLoop == true && v.annotations.last?.filled == true)
            key(v, kVK_ANSI_F, "f")
            path(v, [CGPoint(x: 120, y: 450), CGPoint(x: 200, y: 470), CGPoint(x: 300, y: 430), CGPoint(x: 400, y: 480)])
            check("Kalem: açık çizgi doldurulmadı", v.annotations.last?.filled == false)

            key(v, kVK_ANSI_7, "7")
            var wobble: [CGPoint] = []
            for i in 0...30 { wobble.append(CGPoint(x: 150 + CGFloat(i) * 10, y: 180 + (i % 2 == 0 ? 2 : -2))) }
            path(v, wobble)
            check("Fosforlu kalem düz çizgiye çevrildi", v.annotations.last?.tool == .marker && v.annotations.last?.points.count == 2)

            key(v, kVK_ANSI_8, "8")
            click(v, CGPoint(x: 250, y: 450))
            let tf = v.subviews.compactMap { $0 as? NSTextField }.first
            check("Metin kutusu açıldı", tf != nil)
            tf?.stringValue = "Merhaba"
            v.commitText()
            check("Metin eklendi", v.annotations.last?.text == "Merhaba")
            check("Metin kutusu kapandı", v.subviews.compactMap { $0 as? NSTextField }.isEmpty)

            key(v, kVK_ANSI_0, "0")
            click(v, CGPoint(x: 400, y: 250))
            click(v, CGPoint(x: 450, y: 250))
            let steps = v.annotations.filter { $0.tool == .step }.map(\.number)
            check("Numaralı adımlar 1, 2", steps == [1, 2])

            key(v, kVK_ANSI_9, "9")
            drag(v, CGPoint(x: 120, y: 120), CGPoint(x: 260, y: 220))
            check("Bulanıklaştırma eklendi", v.annotations.last?.tool == .blur)

            let n = v.annotations.count
            key(v, kVK_ANSI_Z, "z", mods: .command)
            check("⌘Z geri aldı", v.annotations.count == n - 1)

            v.display()
            if let sel = v.selection?.integral, let (png, _) = v.render(), let rep = NSBitmapImageRep(data: png) {
                let scale = CGFloat(v.cgImage.width) / v.bounds.width
                check("PNG boyutu seçimle aynı (\(rep.pixelsWide)×\(rep.pixelsHigh))",
                      rep.pixelsWide == Int((sel.width * scale).rounded()) && rep.pixelsHigh == Int((sel.height * scale).rounded()))
            } else { check("PNG oluşturuldu", false) }

            let before = v.selection
            let annCount = v.annotations.count
            v.expandToFullScreen()
            check("Tam ekran düğmesi: tam ekran", v.selection == v.bounds)
            v.expandToFullScreen()
            check("Tam ekran düğmesi tekrar: önceki alana döndü", v.selection == before)
            check("Geçişlerde çizimler kaybolmadı", v.annotations.count == annCount)

            v.expandToFullScreen()
            key(v, kVK_ANSI_1, "1")
            drag(v, CGPoint(x: 300, y: 300), CGPoint(x: 700, y: 600))
            check("Tam ekrandan sürükleyerek yeniden kırpma", v.selection == CGRect(x: 300, y: 300, width: 400, height: 300))

            v.expandToFullScreen()
            v.previousSelection = nil
            v.expandToFullScreen()
            check("Önceki alan yokken düğme: yeniden seçim moduna geçti", v.selection == nil)

            key(v, kVK_Escape, "\u{1b}")
            check("Esc ekranı kapattı", c.overlays.isEmpty)
            after(0.8) { part2(c) }
        }
    }

    static func part2(_ c: CaptureController) {
        log("— 2) Seçerek çek modu —")
        c.start(allowFullScreen: true)
        waitOverlay(c) { v in
            key(v, kVK_Space, " ")
            check("Boşluk → tam ekran", v.selection == v.bounds)
            v.selection = nil
            key(v, kVK_ANSI_A, "a", mods: .command)
            check("⌘A → tam ekran", v.selection == v.bounds)
            key(v, kVK_Escape, "\u{1b}")
            after(0.8) { part3(c) }
        }
    }

    static func part3(_ c: CaptureController) {
        log("— 3) Tam ekran modu —")
        c.start(fullScreen: true)
        waitOverlay(c) { v in
            check("Tam ekran hazır seçili açıldı", v.selection == v.bounds)
            key(v, kVK_Escape, "\u{1b}")
            after(1.0) { memoryLoop(c, round: 1, readings: []) }
        }
    }

    static func memoryLoop(_ c: CaptureController, round: Int, readings: [Double]) {
        if round > 8 {
            log("— 4) Art arda 8 çekim RAM (kapandıktan sonra): " + readings.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " MB")
            // Sızıntı yoksa son 4 çekimin en yükseği, ilk 4 çekimin en yükseğini geçmemeli
            let growth = (readings.suffix(4).max() ?? 0) - (readings.prefix(4).max() ?? 0)
            check(String(format: "Art arda çekimlerde RAM sınırsız büyümüyor (fark: %.1f MB)", growth), growth < 5)
            log(String(format: "   bilgi: çekimlerden sonra kalan RAM %.0f MB", readings.last ?? 0))
            part5()
            return
        }
        c.start(fullScreen: true)
        waitOverlay(c) { v in
            let b = v.bounds
            v.annotations.append(Annotation(tool: .blur, points: [CGPoint(x: 100, y: 100), CGPoint(x: b.width - 100, y: b.height - 100)], color: .red, width: 4))
            v.display()
            _ = v.render()
            c.finish(hideApp: false)
            after(1.0) {
                log("   çekim \(round): RAM \(String(format: "%.0f", SelfTest.footprint())) MB, canlı ekran görünümü \(OverlayView.live), canlı pencere \(OverlayWindow.live)")
                memoryLoop(c, round: round + 1, readings: readings + [SelfTest.footprint()])
            }
        }
    }

    static func part5() {
        log("— 5) Kısayol ayarları —")
        let d = UserDefaults.standard
        let keys = ShortcutAction.allCases.map(\.defaultsKey)
        let saved = keys.map { d.object(forKey: $0) }
        let hk = HotKeyCenter.shared
        let full = hk.shortcut(for: .full)
        hk.set(full, for: .region)
        check("Aynı kısayol başka işlemden kaldırıldı", hk.shortcut(for: .region) == full && hk.shortcut(for: .full) == nil)
        hk.set(nil, for: .choose)
        check("Kısayol silinebiliyor", hk.shortcut(for: .choose) == nil)
        for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        hk.registerAll()
        check("Ayarlar eski haline döndü", zip(keys, saved).allSatisfy { k, v in
            (d.object(forKey: k) as? NSObject) == (v as? NSObject) })
        finish()
    }

    static func finish() {
        log(fails == 0 ? "SONUÇ: tüm testler geçti" : "SONUÇ: \(fails) test başarısız")
        exit(fails == 0 ? 0 : 1)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let capture = CaptureController()
    let settings = SettingsController()
    private var statusItem: NSStatusItem!
    private var regionItem: NSMenuItem!
    private var fullItem: NSMenuItem!
    private var chooseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var screenItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        buildStatusItem()
        HotKeyCenter.shared.registerAll()
        LoginItem.refreshLocationIfNeeded()
        // HexDock gibi: izin yoksa açılışta iste → uygulama Sistem Ayarları listesine eklenir.
        if !CommandLine.arguments.contains("--selftest") && !Permissions.screenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(capture) }
        if CommandLine.arguments.contains("--uitest") { UITest.run(capture) }
    }

    func handleHotKey(_ id: UInt32) {
        switch ShortcutAction(rawValue: id) {
        case .region: capture.start(allowFullScreen: false)
        case .full: capture.start(fullScreen: true)
        case .choose: capture.start(allowFullScreen: true)
        case nil: break
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "HexShot'tan Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "Dosya")
        fileMenu.addItem(withTitle: "Kaydet…", action: #selector(OverlayView.saveAction(_:)), keyEquivalent: "s")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Düzen")
        edit.addItem(withTitle: "Geri Al", action: #selector(OverlayView.undoAction(_:)), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "HexShot")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem.sectionHeader(title: "Genel"))
        loginItem = item("Girişte başlat", #selector(toggleLogin))
        menu.addItem(loginItem)
        menu.addItem(item("Kısayollar ve ayarlar…", #selector(openSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "İzinler"))
        screenItem = item("Ekran kaydı", #selector(openScreen))
        menu.addItem(screenItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Ekran görüntüsü"))
        regionItem = item("Alan seç", #selector(takeRegion))
        fullItem = item("Tam ekran", #selector(takeFull))
        chooseItem = item("Seçerek çek", #selector(takeChoose))
        menu.addItem(regionItem)
        menu.addItem(fullItem)
        menu.addItem(chooseItem)

        menu.addItem(.separator())
        menu.addItem(item("HexShot'tan çık", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        func title(_ a: ShortcutAction) -> String {
            if let s = HotKeyCenter.shared.shortcut(for: a) { return "\(a.title)    \(s.display)" }
            return a.title
        }
        regionItem.title = title(.region)
        fullItem.title = title(.full)
        chooseItem.title = title(.choose)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // İzin: verildiyse tik; verilmediyse tıklayınca Sistem Ayarları açılır.
        let ok = Permissions.screenRecording
        screenItem.state = ok ? .on : .off
        screenItem.title = ok ? "Ekran kaydı" : "Ekran kaydı — izin ver…"
    }

    // Menü kapanıp ekrandan silinsin diye kısa bir gecikme
    @objc private func takeRegion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.capture.start(allowFullScreen: false) }
    }

    @objc private func takeFull() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.capture.start(fullScreen: true) }
    }


    @objc private func takeChoose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.capture.start(allowFullScreen: true) }
    }

    @objc private func toggleLogin() { LoginItem.toggle() }
    @objc private func openSettings() { settings.show() }
    @objc private func openScreen() { Permissions.openScreenRecording() }
    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
