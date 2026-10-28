import Foundation

let frame = NotchMeasurement.required(NotchMeasurement.frame, "frame")
let visible = NotchMeasurement.required(NotchMeasurement.visibleFrame, "visibleFrame")
let top = NotchMeasurement.required(NotchMeasurement.safeAreaTop, "safeAreaTop")
let left = NotchMeasurement.required(NotchMeasurement.auxiliaryTopLeftArea, "auxiliaryTopLeftArea")
let right = NotchMeasurement.required(NotchMeasurement.auxiliaryTopRightArea, "auxiliaryTopRightArea")
let width = frame.width - left.width - right.width
let menuHeight = NotchMeasurement.required(NotchMeasurement.menuBarHeight, "menuBarHeight")
precondition(width == CaptionIslandLayout.notchWidth(auxiliaryTopLeft: left, auxiliaryTopRight: right))
precondition(left.maxX == frame.midX - width / 2 && right.minX == frame.midX + width / 2)
precondition(top == left.height && top == right.height)
precondition(menuHeight == 33 && top == 32)
for widthLevel in CaptionSizeLevel.allCases {
    for heightLevel in CaptionSizeLevel.allCases {
        let content = CaptionIslandLayout.notchContentSize(visibleFrame: visible,
            widthLevel: widthLevel, heightLevel: heightLevel)
        let cap = CaptionIslandLayout.expandedContentHeight(visibleHeight: visible.height, heightLevel: heightLevel)
        let result = CaptionIslandLayout.notchedWindowFrame(screenFrame: frame,
            notchHeight: menuHeight, contentSize: content)
        precondition(result.midX == frame.midX && result.maxY == frame.maxY)
        precondition(result.height == cap + menuHeight + 15)
        let expected: CGFloat = widthLevel == .small ? 420 : widthLevel == .medium ? 560 : 800
        precondition(result.width == expected)
    }
}
let compactWidth = CaptionIslandLayout.compactWidth(notchWidth: width)
precondition(compactWidth == width + 240)
let compact = CaptionIslandLayout.notchedWindowFrame(screenFrame: frame, notchHeight: menuHeight,
    contentSize: CGSize(width: compactWidth - 30, height: 12))
precondition(compact.midX == frame.midX && compact.maxY == frame.maxY)
precondition(compact.maxX - right.minX == 120)
precondition(left.maxX - compact.minX == 120)
// A missing field must fail explicitly; radius is deliberately not needed by geometry.
if CommandLine.arguments.contains("--missing") {
    let _: CGFloat = NotchMeasurement.required(nil, "safeAreaTop")
}
print("PASS measured notch geometry: nine expanded sizes, compact wings, physical/menu height distinction")
