import ChatUI
import SwiftUI

struct UsageHeatmapView: View {
    let dailyUsage: [String: Int]

    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private let columns = 52
    private let rows = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(0 ..< columns, id: \.self) { colIndex in
                        VStack(spacing: 4) {
                            ForEach(0 ..< rows, id: \.self) { rowIndex in
                                let date = dateFor(col: colIndex, row: rowIndex)
                                let dateString = dateFormatter.string(from: date)
                                let tokens = dailyUsage[dateString] ?? 0

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colorFor(tokens: tokens))
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        }
    }

    /// Logic to get the date for a specific column and row.
    /// Assuming the rightmost column is the current week.
    private func dateFor(col: Int, row: Int) -> Date {
        let today = Date()
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday, 7 = Saturday

        let daysToSubtract = (columns - 1 - col) * 7 + (weekday - 1 - row)
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: today) ?? today
    }

    /// Max tokens calculation to determine color
    private var maxTokens: Int {
        dailyUsage.values.max() ?? 1
    }

    private func colorFor(tokens: Int) -> Color {
        if tokens == 0 {
            return Color(uiColor: ChatUIDesign.Color.black50).opacity(0.1)
        }
        let maxT = max(maxTokens, 1)
        let ratio = Double(tokens) / Double(maxT)

        // Define intensity colors (similar to GitHub)
        // Light green to dark green
        if ratio < 0.25 {
            return Color.green.opacity(0.3)
        } else if ratio < 0.5 {
            return Color.green.opacity(0.5)
        } else if ratio < 0.75 {
            return Color.green.opacity(0.7)
        } else {
            return Color.green
        }
    }
}
