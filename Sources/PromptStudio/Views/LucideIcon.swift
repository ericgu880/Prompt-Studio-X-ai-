import SwiftUI

struct LucideIcon: View {
    enum Kind {
        case pencil
        case copy
        case circleArrowDown
        case externalLink
        case history
        case link
        case pin
        case trash2
    }

    let kind: Kind

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            icon
                .frame(width: 24, height: 24)
                .scaleEffect(side / 24)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .pencil:
            stroked { path in
                path.move(to: CGPoint(x: 17, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 7))
                path.addLine(to: CGPoint(x: 8, y: 20))
                path.addLine(to: CGPoint(x: 3, y: 21))
                path.addLine(to: CGPoint(x: 4, y: 16))
                path.closeSubpath()
                path.move(to: CGPoint(x: 15, y: 5))
                path.addLine(to: CGPoint(x: 19, y: 9))
            }
        case .copy:
            ZStack {
                stroked { path in
                    path.addRoundedRect(in: CGRect(x: 8, y: 8, width: 13, height: 13), cornerSize: CGSize(width: 2, height: 2))
                }
                stroked { path in
                    path.move(to: CGPoint(x: 16, y: 4))
                    path.addQuadCurve(to: CGPoint(x: 14, y: 2), control: CGPoint(x: 16, y: 2))
                    path.addLine(to: CGPoint(x: 4, y: 2))
                    path.addQuadCurve(to: CGPoint(x: 2, y: 4), control: CGPoint(x: 2, y: 2))
                    path.addLine(to: CGPoint(x: 2, y: 14))
                    path.addQuadCurve(to: CGPoint(x: 4, y: 16), control: CGPoint(x: 2, y: 16))
                }
            }
        case .circleArrowDown:
            ZStack {
                stroked { path in
                    path.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
                    path.move(to: CGPoint(x: 12, y: 8))
                    path.addLine(to: CGPoint(x: 12, y: 16))
                    path.move(to: CGPoint(x: 8, y: 12))
                    path.addLine(to: CGPoint(x: 12, y: 16))
                    path.addLine(to: CGPoint(x: 16, y: 12))
                }
            }
        case .externalLink:
            stroked { path in
                path.addRoundedRect(in: CGRect(x: 4, y: 7, width: 13, height: 13), cornerSize: CGSize(width: 2, height: 2))
                path.move(to: CGPoint(x: 14, y: 4))
                path.addLine(to: CGPoint(x: 20, y: 4))
                path.addLine(to: CGPoint(x: 20, y: 10))
                path.move(to: CGPoint(x: 10, y: 14))
                path.addLine(to: CGPoint(x: 20, y: 4))
            }
        case .history:
            stroked { path in
                path.move(to: CGPoint(x: 3, y: 12))
                path.addCurve(
                    to: CGPoint(x: 12, y: 3),
                    control1: CGPoint(x: 3.5, y: 7),
                    control2: CGPoint(x: 7, y: 3)
                )
                path.addCurve(
                    to: CGPoint(x: 21, y: 12),
                    control1: CGPoint(x: 17, y: 3),
                    control2: CGPoint(x: 21, y: 7)
                )
                path.addCurve(
                    to: CGPoint(x: 12, y: 21),
                    control1: CGPoint(x: 21, y: 17),
                    control2: CGPoint(x: 17, y: 21)
                )
                path.addCurve(
                    to: CGPoint(x: 5.2, y: 18.8),
                    control1: CGPoint(x: 9.3, y: 21),
                    control2: CGPoint(x: 6.8, y: 20.2)
                )
                path.move(to: CGPoint(x: 3, y: 3))
                path.addLine(to: CGPoint(x: 3, y: 8))
                path.addLine(to: CGPoint(x: 8, y: 8))
                path.move(to: CGPoint(x: 12, y: 7))
                path.addLine(to: CGPoint(x: 12, y: 12))
                path.addLine(to: CGPoint(x: 16, y: 14))
            }
        case .link:
            stroked { path in
                path.move(to: CGPoint(x: 10, y: 13))
                path.addCurve(
                    to: CGPoint(x: 13, y: 13),
                    control1: CGPoint(x: 11, y: 14),
                    control2: CGPoint(x: 12, y: 14)
                )
                path.addLine(to: CGPoint(x: 17, y: 9))
                path.addCurve(
                    to: CGPoint(x: 17, y: 5),
                    control1: CGPoint(x: 18.2, y: 7.8),
                    control2: CGPoint(x: 18.2, y: 6.2)
                )
                path.addCurve(
                    to: CGPoint(x: 13, y: 5),
                    control1: CGPoint(x: 15.8, y: 3.8),
                    control2: CGPoint(x: 14.2, y: 3.8)
                )
                path.addLine(to: CGPoint(x: 11, y: 7))
                path.move(to: CGPoint(x: 14, y: 11))
                path.addCurve(
                    to: CGPoint(x: 11, y: 11),
                    control1: CGPoint(x: 13, y: 10),
                    control2: CGPoint(x: 12, y: 10)
                )
                path.addLine(to: CGPoint(x: 7, y: 15))
                path.addCurve(
                    to: CGPoint(x: 7, y: 19),
                    control1: CGPoint(x: 5.8, y: 16.2),
                    control2: CGPoint(x: 5.8, y: 17.8)
                )
                path.addCurve(
                    to: CGPoint(x: 11, y: 19),
                    control1: CGPoint(x: 8.2, y: 20.2),
                    control2: CGPoint(x: 9.8, y: 20.2)
                )
                path.addLine(to: CGPoint(x: 13, y: 17))
            }
        case .pin:
            stroked { path in
                path.move(to: CGPoint(x: 12, y: 17))
                path.addLine(to: CGPoint(x: 12, y: 22))
                path.move(to: CGPoint(x: 5, y: 17))
                path.addLine(to: CGPoint(x: 19, y: 17))
                path.move(to: CGPoint(x: 16, y: 3))
                path.addLine(to: CGPoint(x: 21, y: 8))
                path.move(to: CGPoint(x: 19, y: 6))
                path.addLine(to: CGPoint(x: 12, y: 13))
                path.move(to: CGPoint(x: 12, y: 13))
                path.addLine(to: CGPoint(x: 7, y: 8))
                path.move(to: CGPoint(x: 13, y: 5))
                path.addLine(to: CGPoint(x: 18, y: 10))
            }
        case .trash2:
            stroked { path in
                path.move(to: CGPoint(x: 3, y: 6))
                path.addLine(to: CGPoint(x: 21, y: 6))
                path.move(to: CGPoint(x: 8, y: 6))
                path.addLine(to: CGPoint(x: 9, y: 3))
                path.addLine(to: CGPoint(x: 15, y: 3))
                path.addLine(to: CGPoint(x: 16, y: 6))
                path.addRoundedRect(in: CGRect(x: 6, y: 6, width: 12, height: 18), cornerSize: CGSize(width: 2, height: 2))
                path.move(to: CGPoint(x: 10, y: 11))
                path.addLine(to: CGPoint(x: 10, y: 17))
                path.move(to: CGPoint(x: 14, y: 11))
                path.addLine(to: CGPoint(x: 14, y: 17))
            }
        }
    }

    private func stroked(_ makePath: @escaping (inout Path) -> Void) -> some View {
        var path = Path()
        makePath(&path)
        return path.stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}
