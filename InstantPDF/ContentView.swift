import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 80))
                .foregroundStyle(.gray)
            
            Text("InstantPDF")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 20) {
                InstructionRow(icon: "square.and.arrow.up", text: "1. Tap 'Share' in any app")
                InstructionRow(icon: "doc.text", text: "2. Select 'InstantPDF'")
                InstructionRow(icon: "checkmark", text: "3. PDF is saved to Files")
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            
            Spacer()
            
            Text("No setup required.\nWorks offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct InstructionRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.blue)
            
            Text(text)
                .font(.body)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    ContentView()
}
