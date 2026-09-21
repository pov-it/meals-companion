import SwiftUI

enum Palette {
    static let paper = Color("Paper")
    static let ink = Color("Ink")
    static let terracotta = Color("Terracotta")
    static let muted = Color("Muted")
    static let sage = Color("Sage")
}

enum TypeStyle {
    static let mealTitle = Font.system(.title, design: .serif).weight(.medium)
    static let largeMealTitle = Font.system(.largeTitle, design: .serif).weight(.medium)
    static let caption = Font.system(.subheadline, design: .rounded)
}

extension View {
    func mealsScreenBackground() -> some View {
        self.background(Palette.paper.ignoresSafeArea())
    }
}
