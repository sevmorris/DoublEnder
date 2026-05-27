import SwiftUI

// MARK: - Secondary state views

struct FaceplateErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        FaceplateSecondaryCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(FaceplateDesign.vpAmber)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                FaceplateSecondaryButton("TRY AGAIN", action: onRetry)
            }
        }
    }
}

struct FaceplateUploadingView: View {
    let progress: Double

    var body: some View {
        FaceplateSecondaryCard {
            VStack(spacing: 12) {
                Text("Uploading…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FaceplateDesign.secondaryText)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(FaceplateDesign.vpAmber)
                    .frame(width: 168)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .monospacedDigit()
            }
        }
    }
}

struct FaceplateUploadFailedView: View {
    let onRetry: () -> Void

    var body: some View {
        FaceplateSecondaryCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(FaceplateDesign.vpAmber)
                Text("Recording saved to Desktop. Upload failed — tap Retry to try again.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                FaceplateSecondaryButton("RETRY UPLOAD", action: onRetry)
            }
        }
    }
}
