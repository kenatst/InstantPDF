# App Review Notes

**App Name**: PDF It  
**Bundle ID**: `com.kenatst.pdfit`  
**Share Extension Bundle ID**: `com.kenatst.pdfit.share`  
**Target Platforms**: iOS / iPadOS 17.0+  
**Demo Account / Credentials**: Not Required (App contains no login, accounts, or subscriptions)

---

## 1. App Overview
**PDF It** is a lightweight, on-device utility designed to convert everyday digital content into clean, high-quality PDF files. It operates via:
1. **The Main iOS App**: Allows direct importing of photos, text, links, and documents, along with an organized local PDF library and viewer.
2. **The Share Sheet Extension**: Allows instant conversion directly from Safari, Photos, Notes, and Files without leaving the source app.

---

## 2. Testing the Share Sheet Extension (Recommended Primary Flow)

1. **Safari Webpage Conversion**:
   - Open **Safari** and navigate to any public webpage (e.g., `https://apple.com` or Wikipedia).
   - Tap the iOS **Share button** (`square.and.arrow.up`).
   - Select **PDF It** from the share sheet activities.
   - Choose a mode (**Quick**, **Clean**, or **Reader**) and tap **Create PDF**.
   - Review the generated PDF in the interactive preview; tap **Share** or **Done** to save it to your Library.

2. **Photos Conversion**:
   - Open the **Photos** app and select 1 or more images.
   - Tap **Share** → select **PDF It**.
   - Tap **Create PDF**. The images will be compiled into a multi-page PDF with their aspect ratio preserved.

3. **Notes / Text Conversion**:
   - Open **Notes**, select text or a note, tap **Share** → **PDF It**.
   - Tap **Create PDF**.

---

## 3. Testing In-App Import & Features

1. **Main App Home**:
   - Launch **PDF It**.
   - Tap **Import File** to pick existing files or PDFs.
   - Tap **Photos** to select images via the system photo picker.
   - Tap **Link** to paste any URL for direct rendering.
   - Tap **Text** to enter notes or markdown for conversion.

2. **Library & Viewer**:
   - Switch to the **Library** tab to view saved PDFs.
   - Tap any PDF to open the reader (supports zoom, paging, and pinch gestures).
   - Tap the **Share** button or the **More (...)** menu to test **Rename**, **Save to Files**, **Print**, or **Delete**.

3. **Settings & Legal Information**:
   - From the Home tab, tap the **Settings** gear in the top-right toolbar.
   - Inspect PDF Defaults (Mode, Paper size, Image quality).
   - Review **Privacy Policy**, **Terms of Use**, and **Support & Feedback** links (open in Safari).

---

## 4. Privacy & Network Usage Notes
- PDF It performs all PDF generation directly on the user's device.
- The app requires **no account registration**, **no in-app purchases**, and contains **no third-party SDKs or tracking frameworks**.
- When converting a webpage URL, the app connects directly to the requested website to fetch and render its HTML content into PDF format. No user browsing data is transmitted to or collected by PDF It.

Thank you for your review!
