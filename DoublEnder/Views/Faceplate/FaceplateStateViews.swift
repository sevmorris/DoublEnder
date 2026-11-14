import SwiftUI

// MARK: - Secondary state views

struct FaceplateErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        FaceplateSecondaryCard {
            VStack(spacing: FaceplateDesign.s(12)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: FaceplateDesign.s(30), weight: .semibold))
                    .foregroundStyle(FaceplateDesign.vpAmber)
                Text(message)
                    .font(.system(size: FaceplateDesign.s(11), weight: .medium))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FaceplateDesign.s(8))
                FaceplateSecondaryButton("TRY AGAIN", action: onRetry)
            }
        }
    }
}

struct FaceplateUploadingView: View {
    let progress: Double
    /// Given for an upload that started by itself: LATER stops it, and the
    /// guest can record. A take just stopped uploads without one.
    var onLater: (() -> Void)? = nil

    var body: some View {
        FaceplateSecondaryCard {
            VStack(spacing: FaceplateDesign.s(12)) {
                Text(onLater == nil ? "Uploading…" : "Uploading an earlier recording…")
                    .font(.system(size: FaceplateDesign.s(13), weight: .semibold))
                    .foregroundColor(FaceplateDesign.secondaryText)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(FaceplateDesign.vpAmber)
                    .frame(width: FaceplateDesign.s(168))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: FaceplateDesign.s(14), weight: .bold))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .monospacedDigit()
                if let onLater {
                    FaceplateSecondaryButton("LATER", action: onLater)
                }
            }
        }
    }
}

struct FaceplateUploadFailedView: View {
    let onRetry: () -> Void
    /// LATER: back to the recorder, with the take kept to upload by itself.
    var onLater: (() -> Void)? = nil

    static func message(canPutOff: Bool) -> String {
        canPutOff
            ? "Recording saved to Desktop. Upload failed. Retry now, or choose Later to keep recording: it uploads by itself when the connection is back."
            : "Recording saved to Desktop. Upload failed — tap Retry to try again."
    }

    var body: some View {
        FaceplateSecondaryCard {
            VStack(spacing: FaceplateDesign.s(12)) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: FaceplateDesign.s(30), weight: .semibold))
                    .foregroundStyle(FaceplateDesign.vpAmber)
                Text(Self.message(canPutOff: onLater != nil))
                    .font(.system(size: FaceplateDesign.s(11), weight: .medium))
                    .foregroundColor(FaceplateDesign.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FaceplateDesign.s(8))
                HStack(spacing: FaceplateDesign.s(10)) {
                    FaceplateSecondaryButton("RETRY UPLOAD", action: onRetry)
                    if let onLater {
                        FaceplateSecondaryButton("LATER", action: onLater)
                    }
                }
            }
        }
    }
}
