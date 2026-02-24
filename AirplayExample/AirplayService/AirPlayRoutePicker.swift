import SwiftUI

#if os(iOS)
import AVKit

struct AirPlayRoutePicker: UIViewRepresentable
{
    func makeUIView(context: Context) -> AVRoutePickerView
    {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.activeTintColor = UIColor.systemGreen
        view.tintColor = UIColor.secondaryLabel
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
