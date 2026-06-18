import SwiftUI
import AppKit

class KeyView: NSView {
    var onKeyPress: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        onKeyPress?(event)
    }
}

struct KeyEventHandlingView: NSViewRepresentable {
    let onKeyPress: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKeyPress = onKeyPress
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }
    
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKeyPress = onKeyPress
    }
}

struct OCRRegionOverlayView: View {
    let screenFrame: CGRect
    let onSelected: (CGRect) -> Void
    let onCancelled: () -> Void
    
    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil
    
    var selectedRect: CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }
    
    var body: some View {
        ZStack {
            // Semi-transparent overlay mask
            Canvas { context, size in
                let fullRect = CGRect(origin: .zero, size: size)
                
                // Draw dark mask
                context.fill(Path(fullRect), with: .color(Color.black.opacity(0.35)))
                
                // Clear selection hole
                if let rect = selectedRect {
                    context.blendMode = .clear
                    context.fill(Path(rect), with: .color(.clear))
                    
                    context.blendMode = .normal
                    context.stroke(
                        Path(rect),
                        with: .color(Color(nsColor: .controlAccentColor)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4])
                    )
                }
            }
            .edgesIgnoringSafeArea(.all)
            
            // Premium guidance UI text
            VStack(spacing: 8) {
                Text("Select Speaker OCR Region")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Click and drag a box over the voice chat speaker name area on your screen.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                
                Text("Press ESC to cancel")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 10)
            .position(x: screenFrame.width / 2, y: 120)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startPoint == nil {
                        startPoint = value.startLocation
                    }
                    currentPoint = value.location
                }
                .onEnded { value in
                    if let rect = selectedRect, rect.width > 15, rect.height > 15 {
                        // SwiftUI coordinates: Y increases downwards.
                        // Cocoa coordinates: Y increases upwards from screen bottom.
                        let cocoaRect = CGRect(
                            x: rect.origin.x + screenFrame.origin.x,
                            y: screenFrame.height - rect.origin.y - rect.size.height + screenFrame.origin.y,
                            width: rect.size.width,
                            height: rect.size.height
                        )
                        onSelected(cocoaRect)
                    } else {
                        onCancelled()
                    }
                }
        )
        .background(
            KeyEventHandlingView { event in
                if event.keyCode == 53 { // ESC key
                    onCancelled()
                }
            }
            .frame(width: 1, height: 1)
        )
    }
}

public final class OCRRegionSelector {
    private var window: NSPanel?
    
    public init() {}
    
    public func startSelection(onSelected: @escaping (CGRect) -> Void, onCancelled: @escaping () -> Void) {
        close()
        
        // Find screen where the mouse cursor currently resides
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen = screens.first { NSPointInRect(mouseLocation, $0.frame) } ?? NSScreen.main ?? screens.first
        
        guard let targetScreen = screen else {
            onCancelled()
            return
        }
        
        let frame = targetScreen.frame
        
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        
        let hostingView = NSHostingView(
            rootView: OCRRegionOverlayView(
                screenFrame: frame,
                onSelected: { [weak self] rect in
                    onSelected(rect)
                    self?.close()
                },
                onCancelled: { [weak self] in
                    onCancelled()
                    self?.close()
                }
            )
        )
        
        panel.contentView = hostingView
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        
        // Bring to front
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = panel
    }
    
    public func close() {
        window?.orderOut(nil)
        window = nil
    }
}
