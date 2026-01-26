import SwiftUI
import PDFKit

struct ContentView: View {
    @State private var history: [PDFHistoryItem] = []
    @State private var selectedPDF: PDFHistoryItem?
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Header Box
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.blue.gradient)
                                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            
                            Text("InstantPDF")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                            
                            Text("Convertissez n'importe quoi en PDF via le menu Partager.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(.top, 20)
                        
                        // Instructions
                        VStack(alignment: .leading, spacing: 15) {
                            InstructionRow(icon: "square.and.arrow.up", text: "Tapez 'Partager' dans n'importe quelle app", color: .blue)
                            InstructionRow(icon: "doc.text.magnifyingglass", text: "Sélectionnez 'InstantPDF'", color: .purple)
                            InstructionRow(icon: "checkmark.circle.fill", text: "Prévisualisez et enregistrez", color: .green)
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(20)
                        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
                        .padding(.horizontal)
                        
                        // History Section
                        if !history.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("HISTORIQUE RÉCENT")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                                
                                ForEach(history) { item in
                                    HistoryRow(item: item) {
                                        selectedPDF = item
                                    } onDelete: {
                                        StorageManager.shared.deleteItem(item)
                                        loadHistory()
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        Spacer(minLength: 50)
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear(perform: loadHistory)
            .sheet(item: $selectedPDF) { item in
                if let url = item.absoluteURL {
                    PDFViewerSheet(url: url, title: item.fileName)
                }
            }
        }
    }
    
    private func loadHistory() {
        history = StorageManager.shared.fetchHistory()
    }
}

struct InstructionRow: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.1))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text(text)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }
}

struct HistoryRow: View {
    let item: PDFHistoryItem
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                Image(systemName: "pdf")
                    .font(.title2)
                    .foregroundStyle(.red)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.body)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    
                    Text(item.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }
}

struct PDFViewerSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            PDFKitRepresentedView(url: url)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Fermer") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
