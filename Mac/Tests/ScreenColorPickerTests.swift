import AppKit

func L(_ zh: String, _ en: String) -> String { zh }

@main struct ScreenColorPickerTests {
    static func main() {
        precondition(ScreenColorKeyAction.from(keyCode: 36) == .confirm)
        precondition(ScreenColorKeyAction.from(keyCode: 76) == .confirm)
        precondition(ScreenColorKeyAction.from(keyCode: 53) == .cancel)
        precondition(ScreenColorKeyAction.from(keyCode: 123) == .nudge(123))
        let frame = NSRect(x: -1000, y: 200, width: 1000, height: 800)
        let middle = ScreenSampleRegion.at(NSPoint(x: -900, y: 900), in: frame, scale: 2, cells: 11)
        precondition(middle.rect == CGRect(x: 195, y: 195, width: 11, height: 11))
        precondition(middle.column == 5 && middle.row == 5)
        let corner = ScreenSampleRegion.at(NSPoint(x: -999.9, y: 999.9), in: frame, scale: 2, cells: 11)
        precondition(corner.rect.origin == .zero && corner.column == 0 && corner.row == 0)
        let bottom = ScreenSampleRegion.at(NSPoint(x: -0.1, y: 200.1), in: frame, scale: 2, cells: 11)
        precondition(bottom.column == 10 && bottom.row == 10)
        let scaled = ScreenSampleRegion.at(NSPoint(x: -900, y: 900), in: frame, pixelWidth: 3000, pixelHeight: 1600, cells: 11)
        precondition(scaled.rect.origin == CGPoint(x: 295, y: 195))
        precondition(scaled.column == 5 && scaled.row == 5)
        let nudged = ScreenSampleRegion.nudge(NSPoint(x: -900, y: 900), in: frame, pixelWidth: 3000, pixelHeight: 1600, dx: 1, dy: 0)
        let nextPixel = ScreenSampleRegion.at(nudged, in: frame, pixelWidth: 3000, pixelHeight: 1600, cells: 11)
        precondition(nextPixel.rect.minX + CGFloat(nextPixel.column) == scaled.rect.minX + CGFloat(scaled.column) + 1)
        print("PASS screen color sample coordinates: Retina, secondary display and edges")
    }
}
