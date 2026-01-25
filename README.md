# InstantPDF - Setup Instructions

InstantPDF is a radical simplicity tool to convert shared content to PDF.
Since this project was generated as source files, you need to set up the Xcode project manually.

## 1. Create a New Xcode Project
1. Open Xcode -> **Create a New Xcode Project**.
2. Select **App** (iOS).
3. **Product Name**: `InstantPDF`
4. **Interface**: SwiftUI
5. **Language**: Swift
6. **Organization Identifier**: `com.yourname` (or similar)
7. Save it to a directory.

## 2. Setup Main App
1. Delete the default `InstantPDFApp.swift` and `ContentView.swift` files created by Xcode.
2. Drag and drop the files from the `InstantPDF` folder (generated here) into the Xcode project navigator (Main target).
   - `InstantPDFApp.swift`
   - `ContentView.swift`
   - `Info.plist` (Ensure looking at the Target Settings -> Info tab matches these keys)

## 3. Add Share Extension Target
1. In Xcode, go to File -> New -> **Target**.
2. Select **Share Extension**.
3. Product Name: `ShareExtension`.
4. Finish (Click "Activate" if asked).
5. Delete the default `ShareViewController.swift` and `MainInterface.storyboard` (if created) and `Info.plist`.
   - *Note*: You might need to remove the "Main Interface" key from the Extension Target Deployment Info.
6. Drag and drop the files from the `ShareExtension` folder into the `ShareExtension` group in Xcode.
   - `ShareViewController.swift` (Make sure Target Membership is checked for ShareExtension)
   - `InputProcessor.swift`
   - `PDFRenderer.swift`
   - `Info.plist` (Copy keys to the actual Info.plist or replace it).

## 4. Configuration
1. **Info.plist**: Ensure `NSExtensionActivationRule` in the Share Extension's Info.plist matches the one provided. This controls what appears in the Share Sheet.
2. **Capabilities**: No special capabilities (App Groups, iCloud) are strictly required for the V1 "Share Result" approach, but "App Groups" is recommended if you want to share data between App and Extension later.

## 5. Build & Run
1. Select the `InstantPDF` scheme.
2. Build and Run on Simulator/Device.
3. The app will launch with the instruction screen.
4. Go to **Safari** or **Photos**.
5. Tap **Share**.
6. Look for **InstantPDF** (you might need to tap "Edit Actions..." to enable it).
7. Tap it -> Watch it generate a PDF -> Save to Files.

## Customization
- **Typography**: Edit `PDFRenderer.swift` HTML CSS.
- **Icon**: Add an AppIcon to Assets.xcassets.
